# frozen_string_literal: true

# The column half of the #84 cleanup (see 20260914000000): its migrations
# also added delivery-state columns to ingest_batches and resolved-frame
# columns to exceptions in every tenant before the code was reverted in
# 5521379. Nothing reads them, and the weekly restore drill fails the
# column comparison on every restored tenant. Indexes go first: SQLite
# refuses to drop an indexed column.
class DropOrphanDurableIngestColumns < ActiveRecord::Migration[8.1]
  def up
    remove_index :ingest_batches, :followups_completed_at, if_exists: true
    remove_index :ingest_batches, :delivery_key, if_exists: true
    remove_index :ingest_batches, :batch_id, if_exists: true
    %i[batch_id delivery_key followups followups_completed_at].each do |column|
      remove_column :ingest_batches, column if column_exists?(:ingest_batches, column)
    end
    %i[resolved_frames resolved_frames_key].each do |column|
      remove_column :exceptions, column if column_exists?(:exceptions, column)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "the dropped columns belonged to reverted code; there is nothing to restore"
  end
end
