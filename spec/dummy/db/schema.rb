# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_16_000000) do
  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "alert_rules", force: :cascade do |t|
    t.integer "application_id", null: false
    t.datetime "created_at", null: false
    t.string "event", null: false
    t.json "filters", default: {}, null: false
    t.integer "integration_id", null: false
    t.datetime "updated_at", null: false
    t.index ["application_id"], name: "index_alert_rules_on_application_id"
  end

  create_table "alerts", force: :cascade do |t|
    t.integer "alert_rule_id"
    t.string "burst_key"
    t.datetime "created_at", null: false
    t.integer "delivery_attempts", default: 0, null: false
    t.datetime "delivery_enqueued_until"
    t.string "delivery_key"
    t.datetime "delivery_lease_expires_at"
    t.string "delivery_lease_id"
    t.text "error"
    t.string "event", null: false
    t.integer "integration_id", null: false
    t.integer "issue_id"
    t.datetime "next_delivery_at"
    t.json "payload", default: {}, null: false
    t.datetime "sent_at"
    t.string "status", default: "pending", null: false
    t.integer "summary_alert_id"
    t.datetime "updated_at", null: false
    t.index ["burst_key"], name: "index_alerts_on_burst_key", unique: true
    t.index ["delivery_key"], name: "index_alerts_on_delivery_key", unique: true
    t.index ["issue_id", "event", "created_at"], name: "index_alerts_on_issue_id_and_event_and_created_at"
    t.index ["status", "created_at", "alert_rule_id"], name: "index_alerts_for_burst_reconciliation"
  end

  create_table "anomaly_rules", force: :cascade do |t|
    t.integer "baseline_days", default: 7, null: false
    t.datetime "created_at", null: false
    t.float "deviation", default: 3.0, null: false
    t.boolean "enabled", default: true, null: false
    t.integer "environment_id", null: false
    t.datetime "last_fired_at"
    t.string "metric", null: false
    t.string "target", default: "*", null: false
    t.string "target_kind", null: false
    t.datetime "updated_at", null: false
    t.integer "window_minutes", default: 15, null: false
    t.index ["environment_id"], name: "index_anomaly_rules_on_environment_id"
  end

  create_table "attachments", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.integer "bytes", null: false
    t.string "content_type", limit: 128
    t.binary "data", null: false
    t.string "deploy", limit: 128
    t.string "exception_group_hash", limit: 32
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.string "group_hash", limit: 32
    t.string "name", limit: 255, null: false
    t.datetime "occurred_at", null: false
    t.string "server", limit: 255
    t.string "trace_id", limit: 36
    t.boolean "truncated", default: false, null: false
    t.string "user_ref", limit: 255
    t.index ["exception_group_hash", "occurred_at"], name: "index_attachments_on_exception_group_hash_and_occurred_at"
    t.index ["execution_id"], name: "index_attachments_on_execution_id"
    t.index ["occurred_at"], name: "index_attachments_on_occurred_at"
  end

  create_table "broadcasts", force: :cascade do |t|
    t.string "action", limit: 128
    t.string "app_tenant", limit: 255
    t.integer "bytes"
    t.string "channel", limit: 255
    t.string "deploy", limit: 128
    t.integer "duration", null: false
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.boolean "failed", default: false, null: false
    t.string "group_hash", limit: 32
    t.string "kind", limit: 20, null: false
    t.datetime "occurred_at", null: false
    t.string "server", limit: 255
    t.string "stream", limit: 255
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.index ["execution_id"], name: "index_broadcasts_on_execution_id"
    t.index ["group_hash", "occurred_at"], name: "index_broadcasts_on_group_hash_and_occurred_at"
  end

  create_table "cache_events", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.string "deploy", limit: 128
    t.integer "duration", null: false
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.string "group_hash", limit: 32
    t.integer "hits"
    t.string "key", limit: 255
    t.datetime "occurred_at", null: false
    t.string "server", limit: 255
    t.string "store", limit: 64
    t.string "trace_id", limit: 36
    t.integer "ttl"
    t.string "type", limit: 20, null: false
    t.string "user_ref", limit: 255
    t.index ["execution_id"], name: "index_cache_events_on_execution_id"
    t.index ["group_hash", "occurred_at"], name: "index_cache_events_on_group_hash_and_occurred_at"
  end

  create_table "comments", force: :cascade do |t|
    t.string "author_name"
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.string "external_id"
    t.datetime "external_updated_at"
    t.integer "issue_id", null: false
    t.string "source", default: "railwatch", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["issue_id"], name: "index_comments_on_issue_id"
  end

  create_table "deploys", force: :cascade do |t|
    t.json "commits", default: [], null: false
    t.datetime "created_at", null: false
    t.string "deploy", limit: 128, null: false
    t.datetime "deployed_at", null: false
    t.json "detail", default: {}, null: false
    t.integer "environment_id", null: false
    t.string "name"
    t.string "previous_ref", limit: 128
    t.string "ref", limit: 128
    t.string "server"
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["environment_id", "deploy"], name: "index_deploys_on_environment_id_and_deploy", unique: true
    t.index ["environment_id", "deployed_at"], name: "index_deploys_on_environment_id_and_deployed_at"
  end

  create_table "deprecations", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.string "deploy", limit: 128
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.string "gem_name", limit: 128
    t.string "group_hash", limit: 32
    t.string "horizon", limit: 32
    t.text "message", null: false
    t.datetime "occurred_at", null: false
    t.string "server", limit: 255
    t.string "source", limit: 255
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.index ["group_hash", "occurred_at"], name: "index_deprecations_on_group_hash_and_occurred_at"
  end

  create_table "enqueued_jobs", force: :cascade do |t|
    t.string "adapter", limit: 64
    t.string "app_tenant", limit: 255
    t.string "deploy", limit: 128
    t.integer "duration", null: false
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.boolean "failed", default: false
    t.string "group_hash", limit: 32
    t.string "job_id", limit: 36
    t.string "name", limit: 255, null: false
    t.datetime "occurred_at", null: false
    t.integer "priority"
    t.string "queue", limit: 128
    t.datetime "scheduled_at"
    t.string "server", limit: 255
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.index ["execution_id"], name: "index_enqueued_jobs_on_execution_id"
    t.index ["group_hash", "occurred_at"], name: "index_enqueued_jobs_on_group_hash_and_occurred_at"
    t.index ["job_id"], name: "index_enqueued_jobs_on_job_id"
  end

  create_table "exceptions", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.json "cause"
    t.string "class_name", limit: 255, null: false
    t.text "context"
    t.string "deploy", limit: 128
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.string "file", limit: 255
    t.json "fingerprint", default: [], null: false
    t.string "fingerprint_source", limit: 16
    t.json "frames", default: [], null: false
    t.string "group_hash", limit: 32
    t.boolean "handled", default: false, null: false
    t.integer "line"
    t.json "locals"
    t.text "message", null: false
    t.datetime "occurred_at", null: false
    t.string "rails_version", limit: 16
    t.string "ruby_version", limit: 16
    t.string "server", limit: 255
    t.string "severity", limit: 16
    t.string "source", limit: 128
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.index ["app_tenant", "occurred_at", "id"], name: "idx_exceptions_tenant_cursor"
    t.index ["class_name", "occurred_at", "id"], name: "idx_exceptions_class_cursor"
    t.index ["execution_id"], name: "index_exceptions_on_execution_id"
    t.index ["group_hash", "occurred_at"], name: "index_exceptions_on_group_hash_and_occurred_at"
    t.index ["occurred_at"], name: "index_exceptions_on_occurred_at"
  end

  create_table "executions", force: :cascade do |t|
    t.string "action", limit: 128
    t.integer "allocations"
    t.string "app_tenant", limit: 255
    t.integer "attempt"
    t.string "controller", limit: 255
    t.json "counters", default: {}, null: false
    t.string "deploy", limit: 128
    t.json "detail", default: {}, null: false
    t.integer "duration", null: false
    t.string "exception_preview", limit: 255
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.string "group_hash", limit: 32
    t.string "inertia_component", limit: 255
    t.boolean "inertia_partial", default: false
    t.string "job_id", limit: 36
    t.string "kind", limit: 20, null: false
    t.string "method", limit: 10
    t.string "name", limit: 255, null: false
    t.datetime "occurred_at", null: false
    t.string "outcome", limit: 20
    t.string "parent_id", limit: 36
    t.bigint "peak_memory"
    t.integer "profile_id"
    t.string "queue", limit: 128
    t.integer "queue_latency"
    t.integer "queue_time"
    t.string "route", limit: 255
    t.string "server", limit: 255
    t.json "stages", default: {}, null: false
    t.integer "status"
    t.string "task_key", limit: 128
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.index ["app_tenant", "occurred_at"], name: "index_executions_on_app_tenant_and_occurred_at"
    t.index ["deploy", "occurred_at"], name: "index_executions_on_deploy_and_occurred_at"
    t.index ["execution_id"], name: "index_executions_on_execution_id", unique: true
    t.index ["group_hash", "occurred_at"], name: "index_executions_on_group_hash_and_occurred_at"
    t.index ["kind", "app_tenant", "occurred_at", "id"], name: "idx_executions_kind_tenant_cursor"
    t.index ["kind", "occurred_at"], name: "index_executions_on_kind_and_occurred_at"
    t.index ["kind", "outcome", "occurred_at", "id"], name: "idx_executions_kind_outcome_cursor"
    t.index ["parent_id"], name: "index_executions_on_parent_id"
    t.index ["trace_id"], name: "index_executions_on_trace_id"
    t.index ["user_ref", "occurred_at"], name: "index_executions_on_user_ref_and_occurred_at"
  end

  create_table "gadgets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.datetime "updated_at", null: false
  end

  create_table "health_samples", force: :cascade do |t|
    t.integer "backlog"
    t.string "deploy", limit: 128
    t.json "detail", default: {}, null: false
    t.bigint "memory"
    t.integer "pid"
    t.integer "pool_busy"
    t.integer "pool_size"
    t.integer "pool_waiting"
    t.integer "queue_depth"
    t.integer "queue_latency"
    t.string "role", limit: 20
    t.datetime "sampled_at", null: false
    t.string "server", limit: 255
    t.integer "threads_busy"
    t.integer "threads_max"
    t.index ["sampled_at"], name: "index_health_samples_on_sampled_at"
    t.index ["server", "sampled_at"], name: "index_health_samples_on_server_and_sampled_at"
  end

  create_table "ingest_batches", force: :cascade do |t|
    t.integer "accepted", default: 0, null: false
    t.float "backpressure_factor", default: 1.0, null: false
    t.integer "bytes", default: 0, null: false
    t.json "counts_by_type", default: {}, null: false
    t.integer "dropped_by_client", default: 0, null: false
    t.string "gem_version", limit: 16
    t.datetime "received_at", null: false
    t.integer "rejected", default: 0, null: false
    t.json "rejections", default: [], null: false
    t.index ["received_at"], name: "index_ingest_batches_on_received_at"
  end

  create_table "issue_activities", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.json "data", default: {}, null: false
    t.integer "issue_id", null: false
    t.string "kind", null: false
    t.integer "user_id"
    t.index ["issue_id", "created_at"], name: "index_issue_activities_on_issue_id_and_created_at"
  end

  create_table "issues", force: :cascade do |t|
    t.integer "affected_users", default: 0, null: false
    t.integer "application_id", null: false
    t.integer "assignee_id"
    t.datetime "created_at", null: false
    t.string "culprit"
    t.integer "environment_id", null: false
    t.datetime "first_seen_at", null: false
    t.string "group_hash", limit: 32, null: false
    t.string "kind", default: "exception", null: false
    t.datetime "last_seen_at", null: false
    t.integer "merged_into_id"
    t.integer "number", null: false
    t.bigint "occurrences", default: 0, null: false
    t.string "priority", default: "normal", null: false
    t.datetime "regressed_at"
    t.datetime "resolved_at"
    t.string "resolved_in_deploy", limit: 128
    t.json "sample", default: {}, null: false
    t.string "source", limit: 128
    t.string "status", default: "open", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["application_id", "number"], name: "index_issues_on_application_id_and_number", unique: true
    t.index ["environment_id", "group_hash"], name: "index_issues_on_environment_id_and_group_hash", unique: true
    t.index ["environment_id", "status", "last_seen_at"], name: "index_issues_on_environment_id_and_status_and_last_seen_at"
    t.index ["merged_into_id"], name: "index_issues_on_merged_into_id"
  end

  create_table "llm_calls", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.string "attachment_names", limit: 1024
    t.string "attachment_types", limit: 128
    t.integer "attachments"
    t.integer "cache_read_tokens"
    t.integer "cache_write_tokens"
    t.text "completion"
    t.bigint "cost_nanos"
    t.boolean "cost_reported"
    t.string "deploy", limit: 128
    t.integer "duration", null: false
    t.string "error", limit: 255
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.string "finish_reason", limit: 32
    t.string "group_hash", limit: 32
    t.integer "input_tokens"
    t.integer "message_count"
    t.string "model", limit: 255
    t.datetime "occurred_at", null: false
    t.string "operation", limit: 20, null: false
    t.integer "output_tokens"
    t.json "params"
    t.text "prompt"
    t.string "provider", limit: 64
    t.string "provider_request_id", limit: 128
    t.string "response_model", limit: 255
    t.string "server", limit: 255
    t.string "status", limit: 16
    t.boolean "streaming"
    t.integer "thinking_tokens"
    t.string "tool_call_id", limit: 128
    t.integer "tool_count"
    t.string "tool_name", limit: 255
    t.string "tools", limit: 1024
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.string "workflow_id", limit: 64
    t.string "workflow_name", limit: 255
    t.string "workflow_step_id", limit: 64
    t.string "workflow_step_name", limit: 255
    t.string "workflow_step_parent_id", limit: 64
    t.index ["execution_id"], name: "index_llm_calls_on_execution_id"
    t.index ["group_hash", "occurred_at"], name: "index_llm_calls_on_group_hash_and_occurred_at"
    t.index ["workflow_id", "occurred_at"], name: "index_llm_calls_on_workflow_id_and_occurred_at"
  end

  create_table "logs", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.text "context"
    t.string "deploy", limit: 128
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.string "group_hash", limit: 32
    t.string "level", limit: 10, null: false
    t.text "message", null: false
    t.datetime "occurred_at", null: false
    t.string "server", limit: 255
    t.string "source", limit: 255
    t.json "tags", default: [], null: false
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.index ["app_tenant", "occurred_at", "id"], name: "idx_logs_tenant_cursor"
    t.index ["execution_id"], name: "index_logs_on_execution_id"
    t.index ["level", "occurred_at", "id"], name: "idx_logs_level_cursor"
    t.index ["occurred_at"], name: "index_logs_on_occurred_at"
  end

  create_table "mails", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.integer "attachments", default: 0
    t.integer "bcc", default: 0
    t.integer "cc", default: 0
    t.string "delivery_method", limit: 64
    t.string "deploy", limit: 128
    t.integer "duration", null: false
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.boolean "failed", default: false
    t.string "group_hash", limit: 32
    t.string "mailer", limit: 255, null: false
    t.string "message_id", limit: 255
    t.datetime "occurred_at", null: false
    t.boolean "perform_deliveries", default: true
    t.string "server", limit: 255
    t.string "subject", limit: 255
    t.integer "to", default: 0
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.index ["execution_id"], name: "index_mails_on_execution_id"
    t.index ["group_hash", "occurred_at"], name: "index_mails_on_group_hash_and_occurred_at"
  end

  create_table "n_plus_ones", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.integer "count", null: false
    t.string "deploy", limit: 128
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.string "group_hash", limit: 32
    t.datetime "occurred_at", null: false
    t.string "server", limit: 255
    t.string "source", limit: 255
    t.text "sql", null: false
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.index ["execution_id"], name: "index_n_plus_ones_on_execution_id"
    t.index ["group_hash", "occurred_at"], name: "index_n_plus_ones_on_group_hash_and_occurred_at"
  end

  create_table "notifications", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.string "channel", limit: 64
    t.string "delivery_method", limit: 128
    t.string "deploy", limit: 128
    t.integer "duration", null: false
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.boolean "failed", default: false
    t.string "group_hash", limit: 32
    t.string "notifier", limit: 255
    t.datetime "occurred_at", null: false
    t.string "server", limit: 255
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.index ["group_hash", "occurred_at"], name: "index_notifications_on_group_hash_and_occurred_at"
  end

  create_table "outgoing_requests", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.string "deploy", limit: 128
    t.integer "duration", null: false
    t.string "error", limit: 255
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.string "group_hash", limit: 32
    t.string "host", limit: 255, null: false
    t.string "method", limit: 10, null: false
    t.datetime "occurred_at", null: false
    t.integer "request_size"
    t.text "response_body"
    t.integer "response_size"
    t.string "server", limit: 255
    t.string "source", limit: 255
    t.integer "status_code"
    t.string "trace_id", limit: 36
    t.string "url", limit: 2048
    t.string "user_ref", limit: 255
    t.index ["execution_id"], name: "index_outgoing_requests_on_execution_id"
    t.index ["group_hash", "occurred_at"], name: "index_outgoing_requests_on_group_hash_and_occurred_at"
  end

  create_table "people", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.string "email", limit: 255
    t.integer "exceptions_count", default: 0, null: false
    t.datetime "first_seen_at"
    t.datetime "last_seen_at"
    t.string "name", limit: 255
    t.string "ref", limit: 255, null: false
    t.integer "requests_count", default: 0, null: false
    t.index ["last_seen_at"], name: "index_people_on_last_seen_at"
    t.index ["ref"], name: "index_people_on_ref", unique: true
  end

  create_table "processes", force: :cascade do |t|
    t.float "boot_seconds"
    t.datetime "booted_at", null: false
    t.string "deploy", limit: 128
    t.json "detail", default: {}, null: false
    t.integer "pid"
    t.string "rails_version", limit: 16
    t.string "railwatch_version", limit: 16
    t.string "role", limit: 20
    t.string "ruby_version", limit: 16
    t.string "server", limit: 255
    t.index ["booted_at"], name: "index_processes_on_booted_at"
  end

  create_table "profiles", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.string "deploy", limit: 128
    t.integer "duration", null: false
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.string "group_hash", limit: 32
    t.integer "interval"
    t.string "mode", limit: 8
    t.datetime "occurred_at", null: false
    t.string "profiler", limit: 16, null: false
    t.integer "samples", null: false
    t.string "server", limit: 255
    t.binary "stacks", null: false
    t.integer "stacks_bytes"
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.index ["execution_id"], name: "index_profiles_on_execution_id"
    t.index ["group_hash", "occurred_at"], name: "index_profiles_on_group_hash_and_occurred_at"
    t.index ["occurred_at"], name: "index_profiles_on_occurred_at"
  end

  create_table "queries", force: :cascade do |t|
    t.string "adapter", limit: 32
    t.integer "allocations"
    t.string "app_tenant", limit: 255
    t.boolean "async", default: false
    t.string "connection", limit: 64
    t.string "deploy", limit: 128
    t.integer "duration", null: false
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.text "explain"
    t.string "group_hash", limit: 32
    t.boolean "in_transaction", default: false
    t.string "name", limit: 255
    t.datetime "occurred_at", null: false
    t.string "role", limit: 16
    t.integer "row_count"
    t.string "server", limit: 255
    t.string "source", limit: 255
    t.text "sql", null: false
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.index ["app_tenant", "duration", "id"], name: "idx_queries_tenant_duration_cursor"
    t.index ["duration", "id", "occurred_at"], name: "idx_queries_slowest", order: { duration: :desc, id: :desc }
    t.index ["duration", "id"], name: "idx_queries_duration_cursor"
    t.index ["execution_id", "occurred_at"], name: "index_queries_on_execution_id_and_occurred_at"
    t.index ["group_hash", "occurred_at"], name: "idx_queries_explained", where: "explain IS NOT NULL"
    t.index ["group_hash", "occurred_at"], name: "index_queries_on_group_hash_and_occurred_at"
    t.index ["occurred_at", "duration"], name: "index_queries_on_occurred_at_and_duration"
  end

  create_table "query_shapes", id: false, force: :cascade do |t|
    t.string "group_hash", limit: 32, null: false
    t.text "sql", null: false
    t.index ["group_hash"], name: "index_query_shapes_on_group_hash", unique: true
  end

  create_table "release_health", force: :cascade do |t|
    t.datetime "bucket", null: false
    t.string "deploy", limit: 128, null: false
    t.integer "duration_count", default: 0
    t.bigint "duration_sum", default: 0
    t.integer "sessions", default: 0
    t.integer "sessions_crashed", default: 0
    t.integer "sessions_errored", default: 0
    t.integer "users", default: 0
    t.integer "users_crashed", default: 0
    t.index ["deploy", "bucket"], name: "index_release_health_on_deploy_and_bucket", unique: true
  end

  create_table "rollups", force: :cascade do |t|
    t.datetime "bucket", null: false
    t.bigint "client_error_count", default: 0, null: false
    t.bigint "count", default: 0, null: false
    t.binary "digest"
    t.integer "duration_max", default: 0, null: false
    t.bigint "duration_sum", default: 0, null: false
    t.bigint "error_count", default: 0, null: false
    t.json "extra", default: {}, null: false
    t.string "group_hash", limit: 32, null: false
    t.string "name", limit: 255, null: false
    t.integer "p50", default: 0, null: false
    t.integer "p95", default: 0, null: false
    t.integer "p99", default: 0, null: false
    t.string "record_type", limit: 32, null: false
    t.index ["record_type", "bucket"], name: "index_rollups_on_record_type_and_bucket"
    t.index ["record_type", "group_hash", "bucket"], name: "index_rollups_on_record_type_and_group_hash_and_bucket", unique: true
  end

  create_table "saved_views", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "environment_id", null: false
    t.string "name", null: false
    t.string "page", null: false
    t.json "params", default: {}, null: false
    t.boolean "pinned", default: true, null: false
    t.string "query"
    t.boolean "shared", default: true, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.string "window", limit: 8
    t.index ["environment_id", "page"], name: "index_saved_views_on_environment_id_and_page"
  end

  create_table "sessions", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.string "deploy", limit: 128
    t.integer "duration"
    t.boolean "ended", default: false
    t.integer "error_count", default: 0
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.string "group_hash", limit: 32
    t.datetime "occurred_at", null: false
    t.integer "requests", default: 0
    t.string "server", limit: 255
    t.string "session_id", limit: 64, null: false
    t.string "source", limit: 16
    t.datetime "started_at"
    t.string "status", limit: 16
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.integer "visits", default: 0
    t.index ["deploy", "occurred_at"], name: "index_sessions_on_deploy_and_occurred_at"
    t.index ["occurred_at"], name: "index_sessions_on_occurred_at"
    t.index ["session_id", "occurred_at"], name: "index_sessions_on_session_id_and_occurred_at"
  end

  create_table "spans", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.string "deploy", limit: 128
    t.integer "duration", null: false
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.string "group_hash", limit: 32
    t.string "name", limit: 255, null: false
    t.datetime "occurred_at", null: false
    t.json "payload", default: {}, null: false
    t.string "server", limit: 255
    t.string "status", limit: 20
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.index ["execution_id", "occurred_at"], name: "index_spans_on_execution_id_and_occurred_at"
    t.index ["group_hash", "occurred_at"], name: "index_spans_on_group_hash_and_occurred_at"
  end

  create_table "storage_ops", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.string "deploy", limit: 128
    t.integer "duration", null: false
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.string "group_hash", limit: 32
    t.string "key", limit: 255
    t.datetime "occurred_at", null: false
    t.string "op", limit: 32, null: false
    t.string "server", limit: 255
    t.string "service", limit: 64
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.index ["group_hash", "occurred_at"], name: "index_storage_ops_on_group_hash_and_occurred_at"
  end

  create_table "thresholds", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "environment_id", null: false
    t.float "limit", null: false
    t.string "metric", default: "p95", null: false
    t.string "target", default: "*", null: false
    t.string "target_kind", null: false
    t.datetime "updated_at", null: false
    t.integer "window_minutes", default: 5, null: false
    t.index ["environment_id", "target_kind", "target", "metric"], name: "index_thresholds_unique", unique: true
  end

  create_table "transactions", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.string "connection", limit: 64
    t.string "deploy", limit: 128
    t.integer "duration", null: false
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.string "group_hash", limit: 32
    t.datetime "occurred_at", null: false
    t.string "outcome", limit: 20
    t.string "server", limit: 255
    t.integer "statement_count"
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.index ["execution_id"], name: "index_transactions_on_execution_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.string "name"
    t.datetime "updated_at", null: false
  end

  create_table "view_renders", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.integer "cache_hits"
    t.integer "count"
    t.string "deploy", limit: 128
    t.integer "duration", null: false
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.string "group_hash", limit: 32
    t.string "identifier", limit: 255, null: false
    t.string "kind", limit: 20
    t.string "layout", limit: 255
    t.datetime "occurred_at", null: false
    t.string "server", limit: 255
    t.string "trace_id", limit: 36
    t.string "user_ref", limit: 255
    t.index ["execution_id"], name: "index_view_renders_on_execution_id"
    t.index ["group_hash", "occurred_at"], name: "index_view_renders_on_group_hash_and_occurred_at"
  end

  create_table "visits", force: :cascade do |t|
    t.string "app_tenant", limit: 255
    t.float "cls"
    t.string "component", limit: 255
    t.string "deploy", limit: 128
    t.integer "duration", null: false
    t.string "execution_id", limit: 36
    t.string "execution_preview", limit: 255
    t.string "execution_source", limit: 20
    t.string "execution_stage", limit: 32
    t.string "group_hash", limit: 32
    t.integer "inp"
    t.integer "lcp"
    t.string "method", limit: 10
    t.datetime "occurred_at", null: false
    t.json "only", default: [], null: false
    t.boolean "partial", default: false
    t.integer "props_bytes"
    t.string "server", limit: 255
    t.string "status", limit: 20
    t.string "trace_id", limit: 36
    t.integer "ttfb"
    t.string "url", limit: 2048
    t.string "user_agent", limit: 255
    t.string "user_ref", limit: 255
    t.index ["group_hash", "occurred_at"], name: "index_visits_on_group_hash_and_occurred_at"
  end

  create_table "widgets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "gadget_id"
    t.string "name"
    t.datetime "updated_at", null: false
  end

  # Virtual tables defined in this database.
  # Note that virtual tables may not work with other database engines. Be careful if changing database.
  create_virtual_table "logs_fts", "fts5", ["message", "content='logs'", "content_rowid='id'"]
end
