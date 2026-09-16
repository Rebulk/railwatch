# frozen_string_literal: true

# Tier 1-3 telemetry: custom spans, process health samples, request queue
# time, web vitals on visits, and an FTS5 index over log messages.
class AddSpansHealthVitalsAndFts < ActiveRecord::Migration[8.1]
  def up
    create_table :spans do |t|
      # The record envelope as it was when this migration shipped; inlined so
      # the history never calls a model that has since changed.
      t.datetime :occurred_at, null: false, precision: 6
      t.string :deploy, limit: 128
      t.string :server, limit: 255
      t.string :group_hash, limit: 32
      t.string :trace_id, limit: 36
      t.string :execution_source, limit: 20
      t.string :execution_id, limit: 36
      t.string :execution_preview, limit: 255
      t.string :execution_stage, limit: 32
      t.string :user_ref, limit: 255
      t.string :app_tenant, limit: 255
      t.string :name, null: false, limit: 255
      t.integer :duration, null: false               # microseconds
      t.json :attributes, null: false, default: {}
      t.string :status, limit: 20                    # ok, failed
    end
    add_index :spans, [ :group_hash, :occurred_at ]
    add_index :spans, [ :execution_id, :occurred_at ]

    # Periodic Puma / Solid Queue samples, one row per process per interval.
    create_table :health_samples do |t|
      t.datetime :sampled_at, null: false, precision: 6
      t.integer :pid
      t.string :role, limit: 20
      t.string :server, limit: 255
      t.string :deploy, limit: 128
      t.integer :threads_max
      t.integer :threads_busy
      t.integer :backlog
      t.integer :pool_size
      t.integer :pool_busy
      t.integer :pool_waiting
      t.integer :queue_depth
      t.integer :queue_latency                        # microseconds, oldest ready job
      t.bigint :memory
      t.json :detail, null: false, default: {}
    end
    add_index :health_samples, [ :server, :sampled_at ]
    add_index :health_samples, :sampled_at

    add_column :executions, :queue_time, :integer      # microseconds, from X-Request-Start
    add_column :executions, :parent_id, :string, limit: 36
    add_index :executions, :parent_id

    add_column :visits, :lcp, :integer                 # milliseconds
    add_column :visits, :cls, :float
    add_column :visits, :inp, :integer                 # milliseconds
    add_column :visits, :ttfb, :integer                # milliseconds

    add_column :queries, :explain, :text                # captured plan for slow queries (opt-in)

    # External-content FTS5 index over log messages. Kept in sync explicitly
    # by Ingest::Writer (insert) and PruneTelemetryJob (rebuild) rather than
    # by triggers: the schema dumper carries create_virtual_table but not
    # triggers, so a tenant created from telemetry_schema.rb would silently
    # lose them.
    execute "CREATE VIRTUAL TABLE logs_fts USING fts5(message, content='logs', content_rowid='id')"
    execute "INSERT INTO logs_fts(rowid, message) SELECT id, message FROM logs"
  end

  def down
    execute "DROP TABLE IF EXISTS logs_fts"
    remove_column :queries, :explain
    remove_column :visits, :lcp
    remove_column :visits, :cls
    remove_column :visits, :inp
    remove_column :visits, :ttfb
    remove_column :executions, :queue_time
    remove_column :executions, :parent_id
    drop_table :health_samples
    drop_table :spans
  end
end
