# frozen_string_literal: true

module Railwatch
  module Export
    # Speaks the receipt protocol: names the delivery so the receiver can
    # recognise a repeat of it, and turns the answer into something the queue
    # can act on.
    #
    # It makes one attempt and has no opinion about when to try again. That
    # belongs to the queue, which is the thing with durable storage.
    class Client
      Outcome = Struct.new(:disposition, :status, :reason, :retry_after_at, :ack, keyword_init: true)

      def initialize(config)
        @config = config
        @transport = Transport::Http.new(config, endpoint: config.resolved_export_url)
      end

      def send(claim, producer_id:)
        result = @transport.deliver_encoded(
          body: claim.body, expected_count: claim.record_count, batch_id: claim.delivery_id,
          dropped: claim.metadata.fetch("dropped", 0).to_i,
          dropped_bytes: claim.metadata.fetch("dropped_bytes", 0).to_i,
          headers: headers(claim, producer_id)
        )
        interpret(result)
      end

      def reset_after_fork!
        @transport = Transport::Http.new(@config, endpoint: @config.resolved_export_url)
        self
      end

      private

      def headers(claim, producer_id)
        {
          "X-Railwatch-Producer-Id" => producer_id,
          "X-Railwatch-Body-SHA256" => Digest::SHA256.hexdigest(claim.body),
          "X-Railwatch-Policy" => claim.metadata.fetch("policy", Policy::Everything::VERSION)
        }
      end

      # The receiver's answer, reduced to what the queue needs to decide.
      # Anything it cannot read is treated as "not stored": keeping bytes we
      # might not need costs a retry, discarding bytes that never arrived
      # costs the telemetry.
      def interpret(result)
        return Outcome.new(disposition: :stored, status: result.status, ack: result.to_h) if stored?(result)
        return Outcome.new(disposition: :rejected, status: result.status, reason: reason_for(result)) if rejected?(result)

        Outcome.new(disposition: :deferred, status: result.status, reason: reason_for(result),
                    retry_after_at: result.retry_after_at)
      end

      # A 200 that stored the records, or a duplicate the receiver already
      # holds -- both mean this delivery is done.
      def stored?(result)
        result.ok && !result.deferred?
      end

      # Permanently unacceptable: sending it again cannot change the answer.
      # 409 is a delivery id reused for different bytes, 410 one too old to be
      # recognised; both are ours to stop retrying, not the receiver's.
      def rejected?(result)
        result.disposition == :permanent || [ 400, 409, 410, 413, 422 ].include?(result.status)
      end

      def reason_for(result)
        (result.reason || result.error || result.status).to_s[0, 64]
      end
    end
  end
end
