# frozen_string_literal: true

module Railwatch
  module Telemetry
    # One immutable delivery waiting to be sent, or the record of one that no
    # longer is. The body is the exact bytes that will go on the wire, kept
    # until the delivery reaches a terminal state and then freed: a retry has
    # to be the same delivery, and the receiver recognises it by those bytes.
    class ExportDelivery < TelemetryRecord
      DISPOSITIONS = %w[acked rejected expired discarded].freeze

      belongs_to :export_destination

      scope :live, -> { where.not(state: "done") }
      scope :due, ->(now = Time.current) { live.where(state: "pending").where(next_attempt_at: ..now) }
      scope :overdue, ->(now = Time.current) { live.where(expires_at: ...now) }
      scope :oldest_first, -> { order(:id) }

      def live? = state != "done"

      def sending? = state == "sending"

      # True when this claim is still the one allowed to finish the delivery.
      # A sender that stalled past its lease may wake and complete its request
      # anyway; the receiver's receipt makes that harmless, but it must not be
      # able to overwrite what the new owner has since recorded.
      def held_by?(token, generation)
        sending? && claim_token == token && claim_generation == generation
      end
    end
  end
end
