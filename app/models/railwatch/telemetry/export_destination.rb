# frozen_string_literal: true

module Railwatch
  module Telemetry
    # Where this database mirrors its telemetry, and everything durable about
    # that relationship: who we are to the receiver, which token we were bound
    # with, whether it is currently taking deliveries, and who holds the lease
    # to send them.
    class ExportDestination < TelemetryRecord
      STATES = %w[ready deferred unauthorized inactive].freeze
      COUNTERS = %w[acked rejected expired discarded shed].freeze

      has_many :export_deliveries, dependent: :delete_all

      validates :state, inclusion: { in: STATES }

      def self.digest(value) = Digest::SHA256.hexdigest(value.to_s)

      # The binding for this url and token. A different token for the same url
      # is a different binding decision, not a silent rebind: queued bytes
      # were admitted under the old credential and must not follow the new one
      # to whatever tenant it belongs to.
      def self.bind!(url:, token:, now: Time.current)
        row = find_or_initialize_by(url_sha256: digest(url))
        row.url = url
        row.producer_id ||= SecureRandom.uuid
        fingerprint = digest(token)
        if row.persisted? && row.credential_sha256 != fingerprint
          row.update!(credential_sha256: fingerprint, state: "unauthorized", reason: "credential_changed",
                      retry_at: nil)
        else
          row.credential_sha256 = fingerprint
          row.created_at ||= now
          row.save!
        end
        row
      end

      def sendable?(now: Time.current)
        state == "ready" && (retry_at.nil? || retry_at <= now)
      end

      def bump!(counter, by = 1)
        return unless COUNTERS.include?(counter.to_s)

        self.counters = counters.merge(counter.to_s => counters.fetch(counter.to_s, 0) + by)
      end
    end
  end
end
