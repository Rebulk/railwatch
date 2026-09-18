# frozen_string_literal: true

# Release health. `sessions` are the raw records the gem ships -- one per
# browser tab and per authenticated/cookied server session, repeated every
# flush interval, so a session id appears many times and the rollup keeps the
# worst status it saw. `release_health` is the hourly aggregate per deploy
# (the release) that the crash-free rates are read from.
class CreateSessionsAndReleaseHealth < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions do |t|
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
      t.string :session_id, null: false, limit: 64
      t.string :source, limit: 16                        # browser, server
      t.string :status, limit: 16                        # started, ok, errored, crashed
      t.datetime :started_at, precision: 6
      t.integer :duration                                # microseconds, null until the session has one
      t.integer :requests, default: 0
      t.integer :visits, default: 0
      t.integer :error_count, default: 0            # `errors` is a reserved Active Record name
      t.boolean :ended, default: false
    end
    add_index :sessions, [ :session_id, :occurred_at ]
    add_index :sessions, [ :deploy, :occurred_at ]
    add_index :sessions, [ :occurred_at ]

    create_table :release_health do |t|
      t.string :deploy, null: false, limit: 128
      t.datetime :bucket, null: false, precision: 6
      t.integer :sessions, default: 0
      t.integer :sessions_errored, default: 0
      t.integer :sessions_crashed, default: 0
      t.integer :users, default: 0
      t.integer :users_crashed, default: 0
      t.bigint :duration_sum, default: 0
      t.integer :duration_count, default: 0
    end
    add_index :release_health, [ :deploy, :bucket ], unique: true
  end
end
