# frozen_string_literal: true

# One table per record type, matching the gem's wire types one to one.
# Every table starts with the shared envelope. JSON columns hold the
# variable parts; hot filter columns are real columns with indexes.
class CreateTelemetry < ActiveRecord::Migration[8.1]
  def change
    create_table :executions do |t|
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
      t.string :tenant, limit: 255
      t.string :kind, null: false, limit: 20         # request, job_attempt, scheduled_task, command
      t.string :name, null: false, limit: 255        # "GET /widgets/:id", "WidgetJob", "rake db:migrate"
      t.integer :duration, null: false               # microseconds
      t.integer :status                              # http status, or exit code
      t.string :outcome, limit: 20                   # processed, failed, aborted
      t.string :method, limit: 10
      t.string :route, limit: 255
      t.string :controller, limit: 255
      t.string :action, limit: 128
      t.string :queue, limit: 128
      t.integer :attempt
      t.integer :queue_latency
      t.string :job_id, limit: 36
      t.string :task_key, limit: 128
      t.string :inertia_component, limit: 255
      t.boolean :inertia_partial, default: false
      t.integer :allocations
      t.bigint :peak_memory
      t.string :exception_preview, limit: 255
      t.json :stages, null: false, default: {}
      t.json :counters, null: false, default: {}
      t.json :detail, null: false, default: {}     # headers, payload, url, ip, user agent, context, extras
    end
    add_index :executions, [ :kind, :occurred_at ]
    add_index :executions, [ :group_hash, :occurred_at ]
    add_index :executions, :execution_id, unique: true
    add_index :executions, :trace_id
    add_index :executions, [ :user_ref, :occurred_at ]
    add_index :executions, [ :deploy, :occurred_at ]
    add_index :executions, [ :tenant, :occurred_at ]

    create_table :queries do |t|
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
      t.string :tenant, limit: 255
      t.text :sql, null: false
      t.string :name, limit: 255
      t.integer :duration, null: false
      t.string :connection, limit: 64
      t.string :adapter, limit: 32
      t.boolean :async, default: false
      t.boolean :in_transaction, default: false
      t.integer :row_count
      t.string :source, limit: 255
      t.integer :allocations
    end
    add_index :queries, [ :group_hash, :occurred_at ]
    add_index :queries, [ :execution_id, :occurred_at ]
    add_index :queries, [ :occurred_at, :duration ]

    create_table :exceptions do |t|
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
      t.string :tenant, limit: 255
      t.string :class_name, null: false, limit: 255
      t.text :message, null: false
      t.boolean :handled, null: false, default: false
      t.string :severity, limit: 16
      t.string :source, limit: 128
      t.string :file, limit: 255
      t.integer :line
      t.json :frames, null: false, default: []
      t.json :cause
      t.text :context
      t.string :ruby_version, limit: 16
      t.string :rails_version, limit: 16
    end
    add_index :exceptions, [ :group_hash, :occurred_at ]
    add_index :exceptions, [ :execution_id ]
    add_index :exceptions, [ :occurred_at ]

    create_table :cache_events do |t|
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
      t.string :tenant, limit: 255
      t.string :store, limit: 64
      t.string :key, limit: 255
      t.string :type, null: false, limit: 20
      t.integer :duration, null: false
      t.integer :ttl
      t.integer :hits
    end
    add_index :cache_events, [ :group_hash, :occurred_at ]
    add_index :cache_events, [ :execution_id ]

    create_table :mails do |t|
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
      t.string :tenant, limit: 255
      t.string :mailer, null: false, limit: 255
      t.string :subject, limit: 255
      t.integer :to, default: 0
      t.integer :cc, default: 0
      t.integer :bcc, default: 0
      t.integer :attachments, default: 0
      t.string :delivery_method, limit: 64
      t.boolean :perform_deliveries, default: true
      t.integer :duration, null: false
      t.boolean :failed, default: false
      t.string :message_id, limit: 255
    end
    add_index :mails, [ :group_hash, :occurred_at ]
    add_index :mails, [ :execution_id ]

    create_table :broadcasts do |t|
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
      t.string :tenant, limit: 255
      t.string :kind, null: false, limit: 20
      t.string :stream, limit: 255
      t.string :channel, limit: 255
      t.string :action, limit: 128
      t.integer :bytes
      t.integer :duration, null: false
    end
    add_index :broadcasts, [ :group_hash, :occurred_at ]
    add_index :broadcasts, [ :execution_id ]

    create_table :notifications do |t|
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
      t.string :tenant, limit: 255
      t.string :notifier, limit: 255
      t.string :delivery_method, limit: 128
      t.integer :duration, null: false
      t.boolean :failed, default: false
    end
    add_index :notifications, [ :group_hash, :occurred_at ]

    create_table :outgoing_requests do |t|
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
      t.string :tenant, limit: 255
      t.string :host, null: false, limit: 255
      t.string :method, null: false, limit: 10
      t.string :url, limit: 2048
      t.integer :duration, null: false
      t.integer :status_code
      t.integer :request_size
      t.integer :response_size
      t.string :error, limit: 255
      t.string :source, limit: 255
    end
    add_index :outgoing_requests, [ :group_hash, :occurred_at ]
    add_index :outgoing_requests, [ :execution_id ]

    create_table :storage_ops do |t|
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
      t.string :tenant, limit: 255
      t.string :service, limit: 64
      t.string :op, null: false, limit: 32
      t.string :key, limit: 255
      t.integer :duration, null: false
    end
    add_index :storage_ops, [ :group_hash, :occurred_at ]

    create_table :view_renders do |t|
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
      t.string :tenant, limit: 255
      t.string :identifier, null: false, limit: 255
      t.string :kind, limit: 20
      t.string :layout, limit: 255
      t.integer :count
      t.integer :cache_hits
      t.integer :duration, null: false
    end
    add_index :view_renders, [ :group_hash, :occurred_at ]
    add_index :view_renders, [ :execution_id ]

    create_table :logs do |t|
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
      t.string :tenant, limit: 255
      t.string :level, null: false, limit: 10
      t.text :message, null: false
      t.json :tags, null: false, default: []
      t.text :context
      t.string :source, limit: 255
    end
    add_index :logs, [ :level, :occurred_at ]
    add_index :logs, [ :execution_id ]
    add_index :logs, [ :occurred_at ]

    create_table :enqueued_jobs do |t|
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
      t.string :tenant, limit: 255
      t.string :job_id, limit: 36
      t.string :name, null: false, limit: 255
      t.string :queue, limit: 128
      t.string :adapter, limit: 64
      t.integer :priority
      t.datetime :scheduled_at, precision: 6
      t.integer :duration, null: false
      t.boolean :failed, default: false
    end
    add_index :enqueued_jobs, [ :group_hash, :occurred_at ]
    add_index :enqueued_jobs, [ :execution_id ]
    add_index :enqueued_jobs, :job_id

    create_table :transactions do |t|
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
      t.string :tenant, limit: 255
      t.integer :duration, null: false
      t.string :outcome, limit: 20
      t.string :connection, limit: 64
    end
    add_index :transactions, [ :execution_id ]

    create_table :n_plus_ones do |t|
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
      t.string :tenant, limit: 255
      t.text :sql, null: false
      t.integer :count, null: false
      t.string :source, limit: 255
    end
    add_index :n_plus_ones, [ :group_hash, :occurred_at ]

    create_table :deprecations do |t|
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
      t.string :tenant, limit: 255
      t.text :message, null: false
      t.string :gem_name, limit: 128
      t.string :horizon, limit: 32
      t.string :source, limit: 255
    end
    add_index :deprecations, [ :group_hash, :occurred_at ]

    create_table :visits do |t|
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
      t.string :tenant, limit: 255
      t.string :component, limit: 255
      t.string :url, limit: 2048
      t.string :method, limit: 10
      t.integer :duration, null: false
      t.string :status, limit: 20
      t.boolean :partial, default: false
      t.json :only, null: false, default: []
      t.integer :props_bytes
      t.string :user_agent, limit: 255
    end
    add_index :visits, [ :group_hash, :occurred_at ]

    create_table :people do |t|
      t.string :ref, null: false, limit: 255     # tenant:id or id
      t.string :name, limit: 255
      t.string :email, limit: 255
      t.string :tenant, limit: 255
      t.datetime :first_seen_at, precision: 6
      t.datetime :last_seen_at, precision: 6
      t.integer :requests_count, null: false, default: 0
      t.integer :exceptions_count, null: false, default: 0
    end
    add_index :people, :ref, unique: true
    add_index :people, :last_seen_at

    create_table :processes do |t|
      t.datetime :booted_at, null: false, precision: 6
      t.integer :pid
      t.string :role, limit: 20
      t.string :server, limit: 255
      t.string :deploy, limit: 128
      t.string :ruby_version, limit: 16
      t.string :rails_version, limit: 16
      t.string :lantern_version, limit: 16
      t.float :boot_seconds
      t.json :detail, null: false, default: {}
    end
    add_index :processes, :booted_at

    # Hourly aggregates per record type and group. Percentiles come from a
    # t-digest blob so they merge across hours without the raw rows.
    create_table :rollups do |t|
      t.datetime :bucket, null: false                # start of the hour, UTC
      t.string :record_type, null: false, limit: 32  # request, job_attempt, query, ...
      t.string :group_hash, null: false, limit: 32
      t.string :name, null: false, limit: 255
      t.bigint :count, null: false, default: 0
      t.bigint :error_count, null: false, default: 0      # 5xx, failed, exceptions
      t.bigint :client_error_count, null: false, default: 0
      t.bigint :duration_sum, null: false, default: 0
      t.integer :duration_max, null: false, default: 0
      t.integer :p50, null: false, default: 0
      t.integer :p95, null: false, default: 0
      t.integer :p99, null: false, default: 0
      t.binary :digest
      t.json :extra, null: false, default: {}
    end
    add_index :rollups, [ :record_type, :group_hash, :bucket ], unique: true
    add_index :rollups, [ :record_type, :bucket ]

    create_table :ingest_batches do |t|
      t.datetime :received_at, null: false, precision: 6
      t.integer :accepted, null: false, default: 0
      t.integer :rejected, null: false, default: 0
      t.integer :dropped_by_client, null: false, default: 0
      t.integer :bytes, null: false, default: 0
      t.string :gem_version, limit: 16
      t.json :counts_by_type, null: false, default: {}
      t.json :rejections, null: false, default: []
    end
    add_index :ingest_batches, :received_at
  end
end
