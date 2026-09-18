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
end
