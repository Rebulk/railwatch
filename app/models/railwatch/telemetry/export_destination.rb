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
      def self.bind!(url:, token:, now: Time.current, retried: false)
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
      rescue ActiveRecord::RecordNotUnique
        # Two processes binding for the first time at once. One row wins; the
        # loser wants that row, not an error.
        raise if retried

        bind!(url: url, token: token, now: now, retried: true)
      end

      # A pause the receiver asked for ends when it said it would. Only a
      # credential problem needs a person: everything else is a delay, and a
      # delay that never ends is an outage we caused ourselves.
      # Needs a person before anything can move again: a credential that was
      # changed, or a destination taken out of service. Queueing into one
      # just fills it with work that rebind! will throw away.
      def blocked? = %w[unauthorized inactive].include?(state)

      def sendable?(now: Time.current)
        return false unless %w[ready deferred].include?(state)

        retry_at.nil? || retry_at <= now
      end

      def bump!(counter, by = 1)
        return unless COUNTERS.include?(counter.to_s)

        self.counters = counters.merge(counter.to_s => counters.fetch(counter.to_s, 0) + by)
      end
    end
  end
end
