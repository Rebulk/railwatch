# frozen_string_literal: true

require "zlib"
require "stringio"
require "json"
require "digest"

module Railwatch
  module Export
    # The durable queue. Every state change a delivery can undergo lives here,
    # and nothing here touches the network.
    #
    # Admission happens inside the caller's ingest transaction, so a batch and
    # its intent to mirror commit together: there is no state where the rows
    # are stored but the delivery was lost, nor one where a delivery exists
    # for rows that rolled back. Everything after that runs in its own short
    # transaction, because the alternative is holding SQLite's write lock
    # across an HTTP request.
    #
    # Two rules the accounting depends on. A delivery leaves the live set by a
    # conditional UPDATE, so two housekeepers racing the same row produce one
    # transition, not two. And the destination row is read fresh inside every
    # transaction that changes it -- a counter adjusted against a snapshot
    # taken earlier is how a queue ends up charged for bodies it has freed,
    # or crediting itself for deliveries it still holds.
    class Outbox
      # A claim handed to a sender: the bytes and the right to finish, with no
      # open database connection attached.
      # Carries the destination it is FOR. A sender reconfigured between the
      # claim and the send must not post these bytes somewhere else.
      Claim = Struct.new(:id, :delivery_id, :body, :record_count, :metadata, :token, :generation,
                         :url, :token_digest, :producer_id, keyword_init: true)

      Admission = Struct.new(:disposition, :record_count, keyword_init: true)

      def initialize(config, environment)
        @config = config
        @environment = environment
      end

      # MUST run inside the caller's telemetry transaction. Returns what to
      # record on the batch's own ledger row, which is how an install can see
      # why a batch mirrored nothing.
      def enqueue!(selections, now: Time.current)
        destination = binding_row
        return Admission.new(disposition: "blocked_config", record_count: 0) unless destination
        return shed(destination, 0, "empty") if selections.empty?
        # A deferred destination still queues -- waiting is what the queue is
        # for. A blocked one does not: those deliveries could only ever be
        # discarded, and they would take capacity from telemetry that can
        # still be sent once somebody fixes it.
        if destination.blocked?
          return shed(destination, selections.sum { |s| s.record_count.to_i }, "blocked_destination")
        end

        admitted = 0
        # A selection with no body is the policy telling us everything it was
        # given was too large to send.
        if (unsendable = selections.reject(&:key)).any?
          return shed(destination, unsendable.sum { |s| s.dropped.to_i }, "shed_oversize")
        end

        selections.each do |selection|
          case admit(destination, selection, now)
          in :admitted then admitted += selection.record_count
          in :duplicate then next
          in :capacity
            # Only what this selection would have been: earlier ones in the
            # same call are already admitted and are not lost.
            return shed(destination, selection.record_count, "shed_capacity")
          end
        end
        Admission.new(disposition: "queued", record_count: admitted)
      end

      def status(now: Time.current)
        destination = binding_row or return { enabled: false, reason: @config.export_problem }

        {
          enabled: true, producer_id: destination.producer_id, url: destination.url,
          state: destination.state, reason: destination.reason,
          queued_deliveries: destination.queued_deliveries, queued_bytes: destination.queued_bytes,
          oldest_queued_at: destination.export_deliveries.queued.oldest_first.pick(:enqueued_at),
          sendable: destination.sendable?(now: now), counters: destination.counters
        }
      end

      # Takes the lease and the oldest delivery that is due, or returns nil.
      # One in flight at a time: a queue draining an outage should do it in
      # order, not open a connection per row.
      def claim!(owner:, now: Time.current)
        destination = binding_row
        return nil unless destination&.sendable?(now: now)

        Telemetry::ExportDelivery.transaction do
          generation = Lease.acquire(destination.id, owner: owner, now: now) or next nil

          reclaim_abandoned(destination, now)
          # Not merely due: still worth sending. Expiry is swept every few
          # minutes, and a restart after a long outage must not post work from
          # before the receiver would still recognise it.
          delivery = destination.export_deliveries.due(now).where(expires_at: now..)
                                .oldest_first.lock.first or next nil

          token = SecureRandom.uuid
          delivery.update!(state: "sending", claim_token: token, claim_generation: generation,
                           claim_expires_at: now + Lease::TTL, attempts: delivery.attempts + 1)
          Claim.new(id: delivery.id, delivery_id: delivery.delivery_id, body: delivery.body,
                    record_count: delivery.record_count, metadata: delivery.wire_metadata,
                    token: token, generation: generation, url: destination.url,
                    token_digest: destination.credential_sha256, producer_id: destination.producer_id)
        end
      end

      # How much one coalesced delivery may carry. Well inside what the
      # receiver accepts in a request (20,000 records, 32 MB), and about what
      # an ordinary reporter batch already sends it, so a merged delivery
      # costs the receiver no more time than the batches it is used to --
      # the request still has to answer inside config.timeout.
      COALESCE_MAX_RECORDS = 500
      COALESCE_MAX_BYTES = 1024 * 1024
      COALESCE_MAX_DELIVERIES = 500

      # Folds the queue's oldest due deliveries into the first of them, so one
      # request carries what would otherwise have taken one round trip each.
      # Returns how many deliveries were folded in (0 when nothing was done).
      #
      # A backlog is almost entirely small deliveries -- one per source batch,
      # a median of one record -- and a round trip costs the same whatever it
      # carries, so sending them one at a time capped the drain at the round
      # trip rate. Merging only when two or more are due makes this
      # self-regulating: a queue that keeps up sends each delivery as it
      # comes, and one that has fallen behind catches up in large steps.
      #
      # Only deliveries that have never been claimed (attempts == 0) are
      # touched. Their ids have never been on the wire, so the receiver has
      # no receipt for them and rewriting their bytes cannot turn a retry
      # into a conflict or a double count. Anything that has been attempted
      # stays byte for byte as it was sent. The merge takes the first run of
      # consecutive untouched deliveries in claim order: never across an
      # attempted one, so no record is carried ahead of one queued before it.
      #
      # The first delivery keeps its row, its id and its delivery id, so
      # order and age are those of the oldest data in it. The rest are
      # finished as "merged" in the same transaction, keeping their selection
      # keys so a replayed batch is still recognised. Decoding and encoding
      # happen before that transaction, which then takes the lease (only its
      # holder merges, as only its holder sends), checks that nothing it read
      # has changed -- expiry and discard run in other processes -- and
      # writes. Call it with no claim of your own in flight: taking the lease
      # moves its generation on, which fences out any claim made under the
      # old one.
      def coalesce!(owner:, now: Time.current)
        destination = binding_row
        return 0 unless destination&.sendable?(now: now) && lease_open_to?(destination, owner, now)

        rows = coalescible(destination, now)
        return 0 if rows.size < 2

        merged = merge(rows) or return 0
        Telemetry::ExportDelivery.transaction do
          Lease.acquire(destination.id, owner: owner, now: now) or next 0
          next 0 unless unchanged?(rows)

          absorb(destination.id, rows, merged, now)
        end
      end

      # Given up voluntarily, so the next process does not wait out the TTL.
      # Only ever our own: the generation check means a lease we already lost
      # is not ours to release.
      def release_lease!(owner:, now: Time.current)
        destination = binding_row or return false
        return false unless destination.lease_owner == owner
        return false if destination.export_deliveries.sending.exists?

        Lease.release(destination.id, owner: owner, generation: destination.lease_generation, now: now)
      end

      def renew!(claim, owner:, now: Time.current)
        destination = binding_row or return false
        return false unless Lease.renew(destination.id, owner: owner, generation: claim.generation, now: now)

        Telemetry::ExportDelivery.where(id: claim.id, claim_token: claim.token)
          .update_all([ "claim_expires_at = ?, updated_at = ?", now + Lease::TTL, now ]) == 1
      end

      # Records what the receiver said. Returns false when this claim is no
      # longer the one allowed to speak for the delivery -- a stale holder
      # whose request landed anyway must not overwrite the new holder's work.
      def finish!(claim, outcome, now: Time.current)
        Telemetry::ExportDelivery.transaction do
          delivery = Telemetry::ExportDelivery.lock.find_by(id: claim.id)
          next false unless delivery&.held_by?(claim.token, claim.generation)

          case outcome.disposition
          when :stored, :acked
            clear_pause(delivery.export_destination_id, now)
            finish(claim.id, "acked", now: now, status: outcome.status, ack: outcome.ack)
          when :rejected then finish(claim.id, "rejected", now: now, status: outcome.status, reason: outcome.reason)
          else defer(delivery, outcome, now)
          end
        end
      end

      # Terminalises whatever has run out of time. A delivery already on the
      # network may still commit at the receiver; expiry means we have stopped
      # waiting for it, not that it did not arrive.
      def expire!(now: Time.current, limit: 200)
        destination = binding_row or return 0

        ids = destination.export_deliveries.overdue(now).limit(limit).pluck(:id)
        ids.count { |id| finish(id, "expired", now: now) }
      end

      # Forgets terminal rows once they are only history. Their bodies are
      # already gone; this is the metadata.
      def prune!(now: Time.current, keep_for: 8 * 24 * 60 * 60, limit: 200)
        destination = binding_row or return 0

        ids = destination.export_deliveries.where(state: "done")
          .where(finished_at: ...(now - keep_for)).limit(limit).pluck(:id)
        return 0 if ids.empty?

        Telemetry::ExportDelivery.where(id: ids).delete_all
      end

      # Abandons everything queued, without contacting anyone. What has
      # already been sent cannot be recalled; this stops what has not.
      def discard_all!(now: Time.current)
        destination = binding_row or return 0

        destination.export_deliveries.live.pluck(:id).count { |id| finish(id, "discarded", now: now) }
      end

      # Clears a credential block, after abandoning the work that was admitted
      # under the old token. Those bytes were promised to whoever that token
      # named; they are not this destination's to deliver now.
      def rebind!(now: Time.current)
        destination = binding_row or return false

        discarded = discard_all!(now: now)
        Telemetry::ExportDestination.where(id: destination.id)
          .update_all(state: "ready", reason: nil, retry_at: nil, updated_at: now)
        discarded
      end

      # Recomputes the counters from the rows themselves. The incremental ones
      # are correct by construction, but a queue that has been through a
      # crash mid-transaction deserves a way to prove it.
      def recount!
        destination = binding_row or return nil

        live = destination.export_deliveries.live
        Telemetry::ExportDestination.where(id: destination.id).update_all(
          queued_deliveries: live.count, queued_bytes: live.sum(:body_bytes), updated_at: Time.current
        )
      end

      # Deliberately not memoised: a counter adjusted against a stale snapshot
      # is the whole bug class this queue has to avoid.
      def binding_row
        return nil unless @config.export?

        Telemetry::ExportDestination.bind!(url: @config.resolved_export_url,
                                           token: @config.resolved_export_token)
      end

      private

      # A cheap look before doing the merge work; Lease.acquire decides.
      def lease_open_to?(destination, owner, now)
        destination.lease_owner.nil? || destination.lease_owner == owner ||
          destination.lease_expires_at.nil? || destination.lease_expires_at < now
      end

      COALESCE_COLUMNS = %i[id body body_sha256 body_bytes ndjson_bytes record_count wire_metadata
                            expires_at attempts].freeze

      # The first run of consecutive due deliveries, in the order claim! takes
      # them, that can travel as one. Attempted deliveries ahead of the run
      # are stepped over (they go first anyway, claimed oldest first); one
      # after it ends it.
      def coalescible(destination, now)
        limit = [ COALESCE_MAX_BYTES, @config.batch_bytes ].min
        rows = []
        records = 0
        bytes = 0
        destination.export_deliveries.due(now).where(expires_at: now..).oldest_first
          .limit(COALESCE_MAX_DELIVERIES).select(*COALESCE_COLUMNS).each do |row|
          untouched = row.attempts.zero? && row.body
          next if rows.empty? && !untouched
          break unless untouched
          break unless rows.empty? || same_wire?(rows.first.wire_metadata, row.wire_metadata)
          break if records + row.record_count > COALESCE_MAX_RECORDS || bytes + row.ndjson_bytes > limit

          rows << row
          records += row.record_count
          bytes += row.ndjson_bytes
        end
        rows
      end

      # The receiver digests these with the body, and they describe how the
      # bytes were built; deliveries built differently are not merged.
      def same_wire?(first, other)
        first["policy"] == other["policy"] && first["version"] == other["version"]
      end

      Merged = Struct.new(:body, :body_sha256, :ndjson_bytes, :record_count, :wire_metadata, keyword_init: true)

      # One gzip member holding every row's NDJSON in queue order. The bodies
      # are decoded rather than concatenated as they stand: a multi-member
      # gzip stream is valid, but a reader that stops after the first member
      # (Ruby's Zlib::GzipReader does) would see only the first delivery.
      def merge(rows)
        io = StringIO.new
        gz = Zlib::GzipWriter.new(io, Zlib::DEFAULT_COMPRESSION, Zlib::DEFAULT_STRATEGY)
        gz.mtime = 0
        rows.each { |row| gz.write(Zlib.gunzip(row.body)) }
        gz.close
        body = io.string.b
        Merged.new(body: body, body_sha256: Digest::SHA256.hexdigest(body),
                   ndjson_bytes: rows.sum(&:ndjson_bytes), record_count: rows.sum(&:record_count),
                   wire_metadata: merged_metadata(rows))
      rescue Zlib::Error => e
        # A body we cannot read will fail on its own when it is sent; it is
        # not a reason to stop draining everything behind it.
        Railwatch.debug { "export coalesce skipped: #{e.class}: #{e.message}" }
        nil
      end

      # Losses add up: a delivery that stands for batches that dropped 3 and
      # 4 records lost 7. Backpressure is a rate the receiver reports as a
      # peak, so the merged delivery carries the highest it was under.
      def merged_metadata(rows)
        wire = rows.first.wire_metadata.dup
        wire["dropped"] = rows.sum { |row| row.wire_metadata.fetch("dropped", 0).to_i }
        wire["dropped_bytes"] = rows.sum { |row| row.wire_metadata.fetch("dropped_bytes", 0).to_i }
        factor = rows.map { |row| row.wire_metadata.fetch("backpressure_factor", 1.0).to_f }.max
        wire["backpressure_factor"] = factor.to_s
        wire
      end

      # Every row read is still pending, never claimed, and holds the bytes
      # that were merged.
      def unchanged?(rows)
        current = Telemetry::ExportDelivery.where(id: rows.map(&:id))
          .pluck(:id, :state, :attempts, :claim_token, :body_sha256).to_h { |id, *rest| [ id, rest ] }
        rows.all? { |row| current[row.id] == [ "pending", 0, nil, row.body_sha256 ] }
      end

      def absorb(destination_id, rows, merged, now)
        head, *rest = rows
        delivery_id = Telemetry::ExportDelivery.where(id: head.id).pick(:delivery_id)
        Telemetry::ExportDelivery.where(id: head.id).update_all(
          body: merged.body, body_sha256: merged.body_sha256, body_bytes: merged.body.bytesize,
          ndjson_bytes: merged.ndjson_bytes, record_count: merged.record_count,
          wire_metadata: merged.wire_metadata,
          metadata_sha256: Digest::SHA256.hexdigest(JSON.generate(merged.wire_metadata.sort.to_h)),
          expires_at: rows.map(&:expires_at).min, updated_at: now
        )
        Telemetry::ExportDelivery.where(id: rest.map(&:id)).update_all(
          state: "done", disposition: "merged", finished_at: now, body: nil,
          last_reason: "merged into #{delivery_id}"[0, 64], updated_at: now
        )
        freed = rows.sum(&:body_bytes) - merged.body.bytesize
        Telemetry::ExportDestination.where(id: destination_id).update_all([
          "queued_bytes = MAX(queued_bytes - ?, 0), queued_deliveries = MAX(queued_deliveries - ?, 0), updated_at = ?",
          freed, rest.size, now
        ])
        bump(Telemetry::ExportDestination.find(destination_id), "merged", rest.size)
        rest.size
      end

      # A holder that vanished leaves its delivery claimed. Once the claim has
      # expired the row goes back in the queue; the fence stops the vanished
      # holder from finishing it later.
      #
      # Runs inside every claim, so it must cost nothing when there is nothing
      # to reclaim -- which is nearly always. index_export_deliveries_sending
      # holds only the rows in flight (one at most), so this reads that entry
      # rather than every row the destination has ever had.
      def reclaim_abandoned(destination, now)
        destination.export_deliveries.sending
          .where(claim_expires_at: ...now)
          .update_all([ "state = 'pending', claim_token = NULL, claim_generation = NULL, claim_expires_at = NULL, updated_at = ?", now ])
      end

      # Not stored, and worth trying again. The delay is ours unless the
      # receiver named a later one -- we never come back sooner than it asked.
      def defer(delivery, outcome, now)
        wait = backoff(delivery.attempts)
        at = [ now + wait, outcome.retry_after_at ].compact.max
        delivery.update!(state: "pending", claim_token: nil, claim_generation: nil, claim_expires_at: nil,
                         next_attempt_at: at, last_status: outcome.status, last_reason: outcome.reason)
        pause_destination(delivery.export_destination_id, outcome, at, now)
        true
      end

      # Only for answers that are about the destination rather than this
      # delivery. A refused token, an exhausted quota, an explicit "slow
      # down" -- those apply to everything queued. A 500 or a timeout is one
      # delivery having a bad time, and pausing the queue for it would turn a
      # blip into an outage.
      # 503 is deliberately absent. A receiver briefly unavailable is this
      # delivery's bad luck; pausing the queue for it would hold up every
      # other delivery behind one unlucky request. 429 and 402 are the
      # receiver telling us something about itself.
      DESTINATION_WIDE = { 401 => "unauthorized", 403 => "unauthorized",
                           402 => "deferred", 429 => "deferred" }.freeze

      # It is taking deliveries again, so stop saying it is not. A credential
      # block is left alone: that one is not ours to decide has passed.
      def clear_pause(destination_id, now)
        Telemetry::ExportDestination.where(id: destination_id, state: "deferred")
          .update_all([ "state = 'ready', reason = NULL, retry_at = NULL, updated_at = ?", now ])
      end

      def pause_destination(destination_id, outcome, at, now)
        state = DESTINATION_WIDE[outcome.status] or return

        Telemetry::ExportDestination.where(id: destination_id).update_all([
          "state = ?, reason = ?, retry_at = ?, updated_at = ?",
          state, (outcome.reason || state).to_s[0, 64], at, now
        ])
      end

      BACKOFF_CEILING = 60

      # Exponential with jitter, so a fleet that lost the receiver together
      # does not come back in lockstep. There is no attempt limit: expiry is
      # the limit, and it is measured in time rather than tries.
      def backoff(attempts)
        ceiling = [ 2**[ attempts - 1, 6 ].min, BACKOFF_CEILING ].min
        ceiling * (0.5 + (SecureRandom.random_number / 2))
      end

      def admit(destination, selection, now)
        # Before the capacity test, not after: work we already hold is not
        # work we are about to lose, and a replay arriving at a full queue
        # would otherwise be counted as a fresh loss every time it retried.
        return :duplicate if destination.export_deliveries.exists?(selection_key: selection.key)
        return :capacity unless room_for?(destination, selection)

        Telemetry::ExportDelivery.create!(
          export_destination: destination, delivery_id: delivery_id(now), selection_key: selection.key,
          body: selection.body, body_sha256: selection.body_sha256,
          metadata_sha256: selection.metadata_sha256, body_bytes: selection.body.bytesize,
          ndjson_bytes: selection.ndjson_bytes, record_count: selection.record_count,
          wire_metadata: selection.metadata, enqueued_at: now,
          expires_at: now + @config.export_max_age, next_attempt_at: now
        )
        charge(destination.id, bytes: selection.body.bytesize, deliveries: 1)
        :admitted
      rescue ActiveRecord::RecordNotUnique
        # The same selection already queued: a batch replayed after a crash,
        # arriving at a queue that already took it. Nothing new was lost.
        :duplicate
      end

      # Capacity is read from the row as it stands, not from whatever it said
      # when this outbox was built.
      def room_for?(destination, selection)
        destination.queued_bytes + selection.body.bytesize <= @config.export_max_bytes &&
          destination.queued_deliveries < @config.export_max_deliveries
      end

      def charge(destination_id, bytes:, deliveries:)
        Telemetry::ExportDestination.where(id: destination_id).update_all([
          "queued_bytes = queued_bytes + ?, queued_deliveries = queued_deliveries + ?, updated_at = ?",
          bytes, deliveries, Time.current
        ])
      end

      # At capacity the new work is refused, not swapped for old work:
      # evicting an already-admitted delivery would lose telemetry we have
      # promised to send in favour of telemetry we have not.
      def shed(destination, records, disposition)
        bump(destination, "shed", records) if records.positive?
        Admission.new(disposition: disposition, record_count: 0)
      end

      # One transaction, and a conditional transition inside it. Two
      # housekeepers reaching the same row produce one terminal delivery and
      # one release of its capacity.
      def finish(id, disposition, now:, status: nil, reason: nil, ack: nil)
        Telemetry::ExportDelivery.transaction do
          delivery = Telemetry::ExportDelivery.lock.find_by(id: id)
          next false unless delivery&.live?

          bytes = delivery.body_bytes
          delivery.update!(state: "done", disposition: disposition, finished_at: now, body: nil,
                           claim_token: nil, claim_generation: nil, claim_expires_at: nil,
                           last_status: status || delivery.last_status,
                           last_reason: reason || delivery.last_reason, ack: ack || delivery.ack)
          release(delivery.export_destination_id, bytes)
          bump(Telemetry::ExportDestination.find(delivery.export_destination_id), disposition, 1)
          true
        end
      end

      # Clamped at zero: a counter that has already been repaired must not be
      # driven negative by a release that arrives afterwards.
      def release(destination_id, bytes)
        Telemetry::ExportDestination.where(id: destination_id).update_all([
          "queued_bytes = MAX(queued_bytes - ?, 0), queued_deliveries = MAX(queued_deliveries - 1, 0), updated_at = ?",
          bytes, Time.current
        ])
      end

      def bump(destination, counter, by)
        destination.bump!(counter, by)
        Telemetry::ExportDestination.where(id: destination.id)
          .update_all(counters: destination.counters, updated_at: Time.current)
      end

      # UUIDv7: time-ordered, and it carries its own creation time so the
      # receiver can age it out without trusting a header.
      def delivery_id(now)
        SecureRandom.uuid_v7(extra_timestamp_bits: 0)
      rescue ArgumentError, NoMethodError
        ms = [ (now.to_f * 1000).to_i, 0 ].max & ((1 << 48) - 1)
        hex = format("%012x", ms) + "7" + SecureRandom.hex(2)[0, 3] +
              (8 + SecureRandom.random_number(4)).to_s(16) + SecureRandom.hex(8)[0, 15]
        [ hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12] ].join("-")
      end
    end
  end
end
