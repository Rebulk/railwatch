# frozen_string_literal: true

module Railwatch
  module Telemetry
    # One immutable delivery waiting to be sent, or the record of one that no
    # longer is. The body is the exact bytes that will go on the wire, kept
    # until the delivery reaches a terminal state and then freed: a retry has
    # to be the same delivery, and the receiver recognises it by those bytes.
    class ExportDelivery < TelemetryRecord
      # merged: folded into an older delivery before either was sent
      # (Outbox#coalesce!); its records travel, and are acknowledged, there.
      DISPOSITIONS = %w[acked rejected expired discarded merged].freeze

      belongs_to :export_destination

      # The state tests are SQL literals, not hash conditions, on purpose.
      # SQLite uses a partial index only when the query repeats the index's
      # WHERE term, and a hash condition is sent as a bound parameter
      # (`state != ?`), which it will not match. With bound parameters the
      # claim fell back to the destination index and read every row the
      # destination ever had -- done ones included -- on every claim.
      scope :live, -> { where("export_deliveries.state <> 'done'") }
      scope :sending, -> { where("export_deliveries.state = 'sending'") }
      # Read through index_export_deliveries_live, which holds only what is
      # still queued. Forced because, with the statistics a young database
      # has (none), SQLite ties it with the plain destination index and may
      # pick that one: 38 ms per claim over 300k done rows, where this is
      # well under one. Needs the `live` term above for the index to apply.
      scope :queued, -> { live.from("#{quoted_table_name} INDEXED BY index_export_deliveries_live") }
      scope :due, ->(now = Time.current) { queued.where(state: "pending").where(next_attempt_at: ..now) }
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
