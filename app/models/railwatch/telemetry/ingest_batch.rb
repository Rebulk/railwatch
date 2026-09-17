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

      # Runs the follow-ups a batch left behind and clears them. Safe to run
      # more than once: the grouping commits a FollowupReceipt per (batch,
      # group) in the railwatch database together with the occurrence count,
      # so a second run finds the receipts and counts nothing. Clearing the
      # outbox here is only what stops the maintenance drain from picking the
      # row up again; it is not what makes the replay safe.
      def drain_followups!(environment)
        work = followups || {}
        ids = Array(work["group_exception_ids"])
        GroupExceptionsJob.new.perform(environment, ids, batch_id: batch_id) if ids.any?
        update_columns(followups: nil)
      end
    end
  end
end
