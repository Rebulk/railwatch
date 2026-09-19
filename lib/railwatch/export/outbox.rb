# frozen_string_literal: true

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
      Claim = Struct.new(:id, :delivery_id, :body, :record_count, :metadata, :token, :generation,
                         keyword_init: true)

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
          oldest_queued_at: destination.export_deliveries.live.oldest_first.pick(:enqueued_at),
          sendable: destination.sendable?(now: now), counters: destination.counters
        }
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
