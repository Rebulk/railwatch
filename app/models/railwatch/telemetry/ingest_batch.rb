# frozen_string_literal: true

module Railwatch
  module Telemetry
    # One row per batch written into the telemetry database. In embedded mode
    # it is also the delivery ledger: `batch_id` is the reporter's stable id
    # for the batch (unique, so a replay is a no-op) and `followups` is the
    # work the batch still owes outside its own transaction, nil once done.
    class IngestBatch < TelemetryRecord
      scope :recent, -> { order(received_at: :desc) }
      scope :with_pending_followups, -> { where.not(followups: nil).order(:received_at) }

      def self.committed(batch_id)
        batch_id.present? ? find_by(batch_id: batch_id) : nil
      end

      # Runs the follow-ups a batch left behind and clears them. Idempotent:
      # grouping the same exception ids twice only bumps nothing, since the
      # issue's occurrence count comes from the rows, not from the call.
      def drain_followups!(environment)
        work = followups || {}
        ids = Array(work["group_exception_ids"])
        GroupExceptionsJob.new.perform(environment, ids) if ids.any?
        update_columns(followups: nil)
      end
    end
  end
end
