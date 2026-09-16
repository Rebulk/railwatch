# frozen_string_literal: true

# The engine's own record of the monitored application: issues and what
# people did about them, saved views, thresholds, anomaly and alert rules,
# deploy markers. Authored and permanent where telemetry is derived and
# pruned, so it lives in the host's `railwatch` database, never its primary.
#
# Nothing here references the host's tables. `viewer_id` on comments,
# activity and saved views is whatever the host's dashboard_user resolver
# returned as `id`, stored as an integer and never joined; `assignee_id`
# on issues is the same. application_id and environment_id are always 1 in
# an embedded install and exist so the dashboard's URLs and the hosted
# platform's code stay identical.
class CreateRailwatchTables < ActiveRecord::Migration[8.1]
  def change
    create_table :railwatch_issues do |t|
      t.integer :application_id, null: false
      t.integer :environment_id, null: false
      t.integer :number, null: false
      t.string :group_hash, limit: 32, null: false
      t.string :kind, default: "exception", null: false
      t.string :title, null: false
      t.string :culprit
      t.string :source, limit: 128
      t.string :status, default: "open", null: false
      t.string :priority, default: "normal", null: false
      t.integer :assignee_id
      t.integer :merged_into_id
      t.bigint :occurrences, default: 0, null: false
      t.integer :affected_users, default: 0, null: false
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.datetime :resolved_at
      t.string :resolved_in_deploy, limit: 128
      t.datetime :regressed_at
      t.json :sample, default: {}, null: false
      t.timestamps
    end
    add_index :railwatch_issues, [ :application_id, :number ], unique: true
    add_index :railwatch_issues, [ :environment_id, :group_hash ], unique: true
    add_index :railwatch_issues, [ :environment_id, :status, :last_seen_at ]
    add_index :railwatch_issues, :merged_into_id

    create_table :railwatch_comments do |t|
      t.integer :issue_id, null: false
      t.integer :viewer_id
      t.string :author_name
      t.text :body, null: false
      t.string :source, default: "railwatch", null: false
      t.string :external_id
      t.datetime :external_updated_at
      t.timestamps
    end
    add_index :railwatch_comments, :issue_id

    create_table :railwatch_issue_activities do |t|
      t.integer :issue_id, null: false
      t.integer :viewer_id
      t.string :kind, null: false
      t.json :data, default: {}, null: false
      t.datetime :created_at, null: false
    end
    add_index :railwatch_issue_activities, [ :issue_id, :created_at ]

    create_table :railwatch_deploys do |t|
      t.integer :environment_id, null: false
      t.string :deploy, limit: 128, null: false
      t.string :ref, limit: 128
      t.string :previous_ref, limit: 128
      t.string :name
      t.string :url
      t.string :server
      t.datetime :deployed_at, null: false
      t.json :commits, default: [], null: false
      t.json :detail, default: {}, null: false
      t.timestamps
    end
    add_index :railwatch_deploys, [ :environment_id, :deploy ], unique: true
    add_index :railwatch_deploys, [ :environment_id, :deployed_at ]

    create_table :railwatch_saved_views do |t|
      t.integer :environment_id, null: false
      t.integer :viewer_id, null: false
      t.string :name, null: false
      t.string :page, null: false
      t.string :query
      t.string :window, limit: 8
      t.json :params, default: {}, null: false
      t.boolean :pinned, default: true, null: false
      t.boolean :shared, default: true, null: false
      t.timestamps
    end
    add_index :railwatch_saved_views, [ :environment_id, :page ]

    create_table :railwatch_thresholds do |t|
      t.integer :environment_id, null: false
      t.string :target_kind, null: false
      t.string :target, default: "*", null: false
      t.string :metric, default: "p95", null: false
      t.float :limit, null: false
      t.integer :window_minutes, default: 5, null: false
      t.timestamps
    end
    add_index :railwatch_thresholds, [ :environment_id, :target_kind, :target, :metric ], unique: true, name: "index_railwatch_thresholds_unique"

    create_table :railwatch_anomaly_rules do |t|
      t.integer :environment_id, null: false
      t.string :target_kind, null: false
      t.string :target, default: "*", null: false
      t.string :metric, null: false
      t.float :deviation, default: 3.0, null: false
      t.integer :baseline_days, default: 7, null: false
      t.integer :window_minutes, default: 15, null: false
      t.boolean :enabled, default: true, null: false
      t.datetime :last_fired_at
      t.timestamps
    end
    add_index :railwatch_anomaly_rules, :environment_id

    create_table :railwatch_alert_rules do |t|
      t.integer :application_id, null: false
      t.string :event, null: false
      t.json :filters, default: {}, null: false
      t.timestamps
    end
    add_index :railwatch_alert_rules, :application_id

    create_table :railwatch_alerts do |t|
      t.integer :alert_rule_id
      t.integer :issue_id
      t.integer :summary_alert_id
      t.string :event, null: false
      t.string :status, default: "pending", null: false
      t.json :payload, default: {}, null: false
      t.text :error
      t.datetime :sent_at
      t.string :burst_key
      t.string :delivery_key
      t.integer :delivery_attempts, default: 0, null: false
      t.datetime :next_delivery_at
      t.datetime :delivery_enqueued_until
      t.string :delivery_lease_id
      t.datetime :delivery_lease_expires_at
      t.timestamps
    end
    add_index :railwatch_alerts, :burst_key, unique: true
    add_index :railwatch_alerts, :delivery_key, unique: true
    add_index :railwatch_alerts, [ :issue_id, :event, :created_at ]
    add_index :railwatch_alerts, [ :status, :created_at, :alert_rule_id ], name: "index_railwatch_alerts_for_burst_reconciliation"
  end
end
