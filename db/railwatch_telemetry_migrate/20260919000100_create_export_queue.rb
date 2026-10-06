# frozen_string_literal: true

# The durable queue an embedded install uses to mirror its telemetry to a
# remote receiver.
#
# Why the bodies are stored rather than re-derived from the rows next door:
# the rows are not a reversible copy of what was sent. Mapping renames and
# drops fields, caps strings, swaps a query's SQL for a shape reference and
# coalesces people; and ingest rejects records the receiver may well accept,
# so sending only what we kept would not be the same telemetry. A delivery
# therefore keeps the exact bytes it will send, and frees them the moment it
# reaches a terminal state -- the cost tracks what is unacknowledged, not what
# is stored.
#
# Nothing here is written unless export is explicitly enabled.
#
# Every statement is if_not_exists, because this migration has run before
# under another number. Through 0.5.0 it was 20260919000000; 0.5.1 moved it
# here so it could not collide with a host's own telemetry migration at that
# number (Railwatch Cloud has one). An install upgrading from 0.5.0 or older
# therefore already holds every table, index and column below, recorded
# under the old version, and sees this one as pending: a plain create_table
# raised "table export_destinations already exists" in db:prepare, which a
# deploy runs before the app boots. The old run is detected by what it
# built, not by its version, because on a host like Railwatch Cloud the old
# number belongs to a different migration.
class CreateExportQueue < ActiveRecord::Migration[8.1]
  def change
    # One row per destination this database has ever been pointed at.
    create_table :export_destinations, if_not_exists: true do |t|
      t.string :url, null: false
      t.string :url_sha256, limit: 64, null: false
      # Permanent for this database's lineage: it is how the receiver tells
      # our deliveries from another installation's.
      t.string :producer_id, limit: 36, null: false
      # A fingerprint, never the token. If the token changes, queued bytes
      # must not follow it to whatever tenant the new one belongs to.
      t.string :credential_sha256, limit: 64, null: false

      t.string :state, limit: 16, null: false, default: "ready"
      t.datetime :retry_at, precision: 6
      t.string :reason, limit: 64

      t.string :lease_owner, limit: 36
      t.bigint :lease_generation, null: false, default: 0
      t.datetime :lease_expires_at, precision: 6

      # Live totals, maintained in the same transaction as the rows they
      # describe, so admission can be decided without counting the table.
      t.bigint :queued_bytes, null: false, default: 0
      t.bigint :queued_deliveries, null: false, default: 0
      # Lifetime accounting: acked, rejected, expired, discarded, shed.
      t.json :counters, null: false, default: {}

      t.timestamps
    end

    add_index :export_destinations, :url_sha256, unique: true, if_not_exists: true
    add_index :export_destinations, :producer_id, unique: true, if_not_exists: true

    create_table :export_deliveries, if_not_exists: true do |t|
      t.references :export_destination, null: false, foreign_key: true
      # A UUIDv7: its embedded time is how the receiver ages it out, so a
      # delivery cannot be made young again by relabelling it.
      t.string :delivery_id, limit: 36, null: false
      # What this delivery is a delivery OF. One per source batch today; a
      # future policy that selects across batches supplies its own key.
      t.string :selection_key, limit: 160, null: false

      t.binary :body
      t.string :body_sha256, limit: 64, null: false
      t.string :metadata_sha256, limit: 64, null: false
      t.bigint :body_bytes, null: false
      t.bigint :ndjson_bytes, null: false
      t.integer :record_count, null: false
      # Everything about the delivery that is not its body: version, drop
      # counts, backpressure. Digested into metadata_sha256 so the same id
      # arriving with different counts is a conflict, not an update.
      t.json :wire_metadata, null: false, default: {}

      t.string :state, limit: 8, null: false, default: "pending"
      # Set only when done: acked, rejected, expired, discarded.
      t.string :disposition, limit: 16
      t.datetime :enqueued_at, null: false, precision: 6
      t.datetime :expires_at, null: false, precision: 6
      t.datetime :next_attempt_at, null: false, precision: 6
      t.bigint :attempts, null: false, default: 0

      t.string :claim_token, limit: 36
      t.bigint :claim_generation
      t.datetime :claim_expires_at, precision: 6

      t.integer :last_status
      t.string :last_reason, limit: 64
      t.json :ack
      t.datetime :finished_at, precision: 6

      t.timestamps
    end

    add_index :export_deliveries, %i[export_destination_id delivery_id], unique: true,
      name: "index_export_deliveries_on_destination_and_delivery", if_not_exists: true
    # One delivery per selection: a batch replayed into the same transaction
    # cannot enqueue itself twice.
    add_index :export_deliveries, %i[export_destination_id selection_key], unique: true,
      name: "index_export_deliveries_on_destination_and_selection", if_not_exists: true
    add_index :export_deliveries, %i[export_destination_id id], where: "state <> 'done'",
      name: "index_export_deliveries_live", if_not_exists: true
    add_index :export_deliveries, :expires_at, where: "body IS NOT NULL",
      name: "index_export_deliveries_expiring", if_not_exists: true
    add_index :export_deliveries, :finished_at, where: "state = 'done'",
      name: "index_export_deliveries_finished", if_not_exists: true

    # Why a batch did or did not enqueue anything. Null on every row an
    # install without export ever writes.
    add_column :ingest_batches, :export_disposition, :string, limit: 24, if_not_exists: true
    add_column :ingest_batches, :export_record_count, :bigint, if_not_exists: true
  end
end
