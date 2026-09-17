# frozen_string_literal: true

# Delivery ledger for in-process ingest. The reporter gives every batch a
# stable id before the first attempt; recording it on the ingest_batches row
# inside the batch transaction lets a retry ask "did this commit?" instead of
# guessing, and lets the follow-up work the batch still owes (exception
# grouping, which writes the other database) be resumed after a crash.
# `followups` is the small outbox: nil once everything has run.
class AddBatchLedgerToIngestBatches < ActiveRecord::Migration[8.1]
  def change
    add_column :ingest_batches, :batch_id, :string, limit: 36
    add_column :ingest_batches, :followups, :json
    add_index :ingest_batches, :batch_id, unique: true
    add_index :ingest_batches, :received_at, where: "followups IS NOT NULL", name: "index_ingest_batches_pending_followups"
  end
end
