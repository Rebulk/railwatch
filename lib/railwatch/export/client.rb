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

      # The queue is bound to a fingerprint of the export credential, so the
      # request has to be made with that credential: authenticating as someone
      # else would deliver these bytes to a tenant that never admitted them.
      def initialize(config)
        @config = config
        @transport = build_transport
      end

      # Not `send`: shadowing Object#send on a class makes it impossible to
      # reach the real one, and reads as a coincidence rather than a verb.
      def deliver(claim, producer_id:)
        result = @transport.deliver_encoded(
          body: claim.body, expected_count: claim.record_count, batch_id: claim.delivery_id,
          dropped: claim.metadata.fetch("dropped", 0).to_i,
          dropped_bytes: claim.metadata.fetch("dropped_bytes", 0).to_i,
          # Stored with the delivery, not read from the reporter now: this is
          # what the batch was carrying when it was queued.
          backpressure_factor: claim.metadata.fetch("backpressure_factor", 1.0).to_f,
          headers: headers(claim, producer_id)
        )
        interpret(result)
      end

      def reset_after_fork!
        @transport = build_transport
        self
      end

      # A fresh transport, dropping any latch the old one had picked up. After
      # a credential problem is fixed, the next send must be an actual send.
      def reset!
        @transport = build_transport
        self
      end

      private

      def build_transport
        credentialed = @config.dup
        credentialed.token = @config.resolved_export_token
        Transport::Http.new(credentialed, endpoint: @config.resolved_export_url)
      end

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
      STORED = %w[committed already_committed].freeze
      REJECTING_STATUSES = [ 400, 409, 410, 413, 422 ].freeze

      def interpret(result)
        return Outcome.new(disposition: :stored, status: result.status, ack: result.to_h) if stored?(result)
        return Outcome.new(disposition: :rejected, status: result.status, reason: reason_for(result)) if rejected?(result)

        Outcome.new(disposition: :deferred, status: result.status, reason: reason_for(result),
                    retry_after_at: result.retry_after_at)
      end

      # A 200 that stored the records, or a duplicate the receiver already
      # holds. When the receiver names what it did, we believe the name and
      # not the arithmetic: counts that happen to add up are not a receipt.
      def stored?(result)
        return false unless result.ok && !result.deferred?
        return STORED.include?(result.ack_disposition) if result.ack_disposition

        true
      end

      # Permanently unacceptable TO THE RECEIVER: sending it again cannot
      # change the answer. 409 is a delivery id reused for different bytes,
      # 410 one too old to be recognised.
      #
      # Deliberately not our own refusals. `:permanent` from the transport
      # means we declined to send -- a latched credential failure, a
      # configuration we will not use -- and throwing the bytes away because
      # of something on this side would destroy telemetry that was never
      # offered to anyone.
      def rejected?(result)
        REJECTING_STATUSES.include?(result.status)
      end

      def reason_for(result)
        (result.reason || result.error || result.status).to_s[0, 64]
      end
    end
  end
end
