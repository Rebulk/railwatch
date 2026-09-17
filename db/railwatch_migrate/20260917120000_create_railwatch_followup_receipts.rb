# frozen_string_literal: true

# What makes replaying a batch's follow-ups safe. Exception grouping bumps an
# issue's occurrence count in this database, but the "done" mark lives on the
# batch's ledger row in the OTHER database, so a crash between the two (or
# the inline drain racing the maintenance drain) would count the same
# exceptions twice. A receipt per (batch, group) is inserted in the same
# transaction as the issue update; the unique index turns a second attempt
# into a no-op.
class CreateRailwatchFollowupReceipts < ActiveRecord::Migration[8.1]
  def change
    create_table :railwatch_followup_receipts do |t|
      t.string :batch_id, limit: 36, null: false
      t.string :group_hash, limit: 32, null: false
      t.datetime :created_at, null: false
    end
    add_index :railwatch_followup_receipts, [ :batch_id, :group_hash ], unique: true
    add_index :railwatch_followup_receipts, :created_at
  end
end
