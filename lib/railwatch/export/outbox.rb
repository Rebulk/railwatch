# frozen_string_literal: true

module Railwatch
  module Export
    # The durable queue. Every state change a delivery can undergo lives here,
    # and nothing here touches the network.
    #
    # Admission happens inside the caller's ingest transaction, so a batch and
    # its intent to mirror commit together: there is no state where the rows
    # are stored but the delivery was lost, nor one where a delivery exists
    # for rows that rolled back. Everything after that -- claiming, finishing,
    # expiring -- runs in its own short transaction, because the alternative
    # is holding SQLite's write lock across an HTTP request.
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
        return Admission.new(disposition: "empty", record_count: 0) if selections.empty?

        destination = binding_row
        return Admission.new(disposition: "blocked_config", record_count: 0) unless destination

        admitted = 0
        selections.each do |selection|
          case admit(destination, selection, now)
          in :admitted then admitted += selection.record_count
          in :capacity then return shed(destination, selections, "shed_capacity")
          in :duplicate then next
          end
        end
        destination.save!
        Admission.new(disposition: "queued", record_count: admitted)
      end

      def status(now: Time.current)
        destination = binding_row or return { enabled: false }

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

        count = 0
        destination.export_deliveries.overdue(now).limit(limit).each do |delivery|
          finish(destination, delivery, "expired", now: now)
          count += 1
        end
        destination.save! if count.positive?
        count
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

        count = 0
        destination.export_deliveries.live.find_each do |delivery|
          finish(destination, delivery, "discarded", now: now)
          count += 1
        end
        destination.save!
        count
      end

      def binding_row
        return @binding if defined?(@binding)

        @binding = if @config.export?
          Telemetry::ExportDestination.bind!(url: @config.resolved_export_url,
                                             token: @config.resolved_export_token)
        end
      end

      private

      def admit(destination, selection, now)
        return :capacity unless room_for?(destination, selection)

        Telemetry::ExportDelivery.create!(
          export_destination: destination, delivery_id: delivery_id(now), selection_key: selection.key,
          body: selection.body, body_sha256: selection.body_sha256,
          metadata_sha256: selection.metadata_sha256, body_bytes: selection.body.bytesize,
          ndjson_bytes: selection.ndjson_bytes, record_count: selection.record_count,
          wire_metadata: selection.metadata, enqueued_at: now,
          expires_at: now + @config.export_max_age, next_attempt_at: now
        )
        destination.queued_bytes += selection.body.bytesize
        destination.queued_deliveries += 1
        :admitted
      rescue ActiveRecord::RecordNotUnique
        # The same selection already queued: a batch replayed after a crash,
        # arriving at a queue that already took it.
        :duplicate
      end

      def room_for?(destination, selection)
        destination.queued_bytes + selection.body.bytesize <= @config.export_max_bytes &&
          destination.queued_deliveries < @config.export_max_deliveries
      end

      # At capacity the new work is refused, not swapped for old work: evicting
      # an already-admitted delivery would lose telemetry we have promised to
      # send in favour of telemetry we have not.
      def shed(destination, selections, disposition)
        destination.bump!("shed", selections.sum(&:record_count))
        destination.save!
        Admission.new(disposition: disposition, record_count: 0)
      end

      def finish(destination, delivery, disposition, now:, status: nil, reason: nil, ack: nil)
        return false unless delivery.live?

        destination.queued_bytes -= delivery.body_bytes
        destination.queued_deliveries -= 1
        destination.bump!(disposition)
        delivery.update!(state: "done", disposition: disposition, finished_at: now, body: nil,
                         claim_token: nil, claim_generation: nil, claim_expires_at: nil,
                         last_status: status || delivery.last_status, last_reason: reason || delivery.last_reason,
                         ack: ack || delivery.ack)
        true
      end

      # UUIDv7: time-ordered, and it carries its own creation time so the
      # receiver can age it out without trusting a header.
      def delivery_id(now)
        ms = (now.to_f * 1000).to_i
        hex = format("%012x", ms) + "7" + SecureRandom.hex(2)[0, 3] +
              (8 + SecureRandom.random_number(4)).to_s(16) + SecureRandom.hex(8)[0, 15]
        [ hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12] ].join("-")
      end
    end
  end
end
