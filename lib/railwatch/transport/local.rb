# frozen_string_literal: true

module Railwatch
  module Transport
    # Writes each batch straight into the engine's telemetry database instead
    # of POSTing it. Same Reporter, same buffer, same backpressure; the only
    # difference from Transport::Http is that deliver ends in Ingest::Batch
    # rather than Net::HTTP. Runs on the reporter thread, never on a request.
    class Local
      Result = Struct.new(:ok, :status, :accepted, :rejected, :rejections, :error, :retryable_error, keyword_init: true) do
        def retryable? = false
      end

      def initialize(config)
        @config = config
      end

      def deliver(records, dropped: 0, dropped_bytes: 0, backpressure_factor: 1.0, batch_id: nil)
        # The gem builds symbol-keyed records; the mapper reads string keys,
        # including inside nested hashes. A JSON round trip is the deep
        # stringify, and it is faster than deep_transform_keys.
        wire = JSON.parse(JSON.generate(records))
        # The reporter thread is not a request or a job: nothing has set up
        # an ExecutionContext for it. Query log tags, Rails.error.report and
        # connection checkin all assume one, so run the write inside the
        # executor the same way a job would.
        result = Rails.application.executor.wrap do
          Ingest::Batch.new(Environment.current, wire, dropped_by_client: dropped,
                            backpressure_factor: backpressure_factor, gem_version: Railwatch::VERSION,
                            embedded: true).write!
        end
        Result.new(ok: true, status: 200, accepted: result.accepted, rejected: result.rejected,
                   rejections: result.rejections.first(10))
      rescue StandardError => e
        Railwatch.debug { "local ingest failed: #{e.class}: #{e.message}" }
        # Written or not, the batch is consumed: retrying would re-run the
        # mapper and could double-insert whatever did commit.
        Result.new(ok: false, error: "#{e.class}: #{e.message}", retryable_error: false)
      end

      def ping = true
      def unauthorized? = false
      def reset_after_fork! = self
    end
  end
end
