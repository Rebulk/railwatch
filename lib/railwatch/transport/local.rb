# frozen_string_literal: true

module Railwatch
  module Transport
    # Writes each batch straight into the engine's telemetry database instead
    # of POSTing it. Same Reporter, same buffer, same backpressure; the only
    # difference from Transport::Http is that deliver ends in Ingest::Batch
    # rather than Net::HTTP. Runs on the reporter thread, never on a request.
    class Local
      Result = Struct.new(:ok, :status, :accepted, :rejected, :rejections, :error, :retryable_error, keyword_init: true) do
        def retryable? = retryable_error ? true : false
      end

      def initialize(config)
        @config = config
      end

      def deliver(records, dropped: 0, dropped_bytes: 0, backpressure_factor: 1.0, batch_id: nil)
        wire = stringify(records)
        # The reporter thread is not a request or a job: nothing has set up
        # an ExecutionContext for it. Query log tags, Rails.error.report and
        # connection checkin all assume one, so run the write inside the
        # executor the same way a job would.
        #
        # The rescue is INSIDE the wrap. The executor reports any exception
        # that escapes its block to Rails.error before re-raising it, and
        # Railwatch subscribes to Rails.error: a write that failed (the
        # telemetry database not migrated yet, a locked file) would otherwise
        # be captured as one of the application's own exceptions and opened
        # as an issue about Railwatch, by Railwatch.
        Rails.application.executor.wrap do
          schema = RuntimeSchema.status(local: true)
          next Result.new(ok: false, status: 503, error: schema.message, retryable_error: true) unless schema.ready?

          write(wire, records.size, dropped: dropped, backpressure_factor: backpressure_factor, batch_id: batch_id)
        rescue StandardError => e
          RuntimeSchema.invalidate! if e.is_a?(ActiveRecord::ActiveRecordError)
          Railwatch.debug { "local ingest failed: #{e.class}: #{e.message}" }
          # With a batch id the reporter can safely retry: the ledger says
          # whether the write committed, and the unique execution_id index
          # makes a replay of a half-visible batch a no-op. Without one (an
          # older caller) the batch is consumed, since a retry could
          # double-insert. A malformed record never gets here: the mapper
          # counts it as rejected and the rest of the batch is written.
          Result.new(ok: false, error: "#{e.class}: #{e.message}", retryable_error: !batch_id.nil?)
        end
      end

      def ping = RuntimeSchema.status(local: true).ready?
      def unauthorized? = false
      def reset_after_fork! = self

      private

      def write(wire, count, dropped:, backpressure_factor:, batch_id:)
        environment = Environment.current
        # The same contract the HTTP path gets from X-Railwatch-Batch-Id: a
        # batch the reporter retries after a failure is written once. The
        # ledger row is created inside the batch transaction, so its presence
        # is the commit.
        if (ledger = environment.with_telemetry { Ingest::Batch.committed(batch_id) })
          return Result.new(ok: true, status: 200, accepted: ledger.accepted, rejected: ledger.rejected, rejections: [])
        end

        result = Ingest::Batch.new(environment, wire, dropped_by_client: dropped, backpressure_factor: backpressure_factor,
                                   gem_version: Railwatch::VERSION, embedded: true, batch_id: batch_id).write!
        Result.new(ok: true, status: 200, accepted: result.accepted, rejected: result.rejected,
                   rejections: result.rejections.first(10))
      end

      # The gem builds symbol-keyed records, nested hashes included (stages,
      # counters, headers); the mapper reads string keys throughout and
      # rejects a symbol-keyed structure. A JSON round trip is the deep
      # stringify. Measured against the alternatives on a 500-record batch:
      # 1.9 ms and 11k allocations here versus 4.8 ms and 25k for
      # deep_transform_keys, which also leaves Symbol values as Symbols.
      def stringify(records)
        JSON.parse(JSON.generate(records))
      end
    end
  end
end
