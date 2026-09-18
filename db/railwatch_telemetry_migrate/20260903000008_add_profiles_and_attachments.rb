# frozen_string_literal: true

# Sampled CPU/wall profiles for an execution, attachments (files an app
# attaches to an execution or exception), and opt-in captured bodies.
class AddProfilesAndAttachments < ActiveRecord::Migration[8.1]
  def change
    create_table :profiles do |t|
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
      t.string :profiler, null: false, limit: 16         # vernier, stackprof
      t.string :mode, limit: 8                           # wall, cpu
      t.integer :interval                                # microseconds between samples
      t.integer :duration, null: false                   # microseconds profiled
      t.integer :samples, null: false                    # total samples collected
      t.binary :stacks, null: false                      # gzip of collapsed stacks: "frame;frame;frame count\n"
      t.integer :stacks_bytes                            # uncompressed size
    end
    add_index :profiles, [ :execution_id ]
    add_index :profiles, [ :group_hash, :occurred_at ]
    add_index :profiles, [ :occurred_at ]

    create_table :attachments do |t|
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
      t.string :content_type, limit: 128
      t.integer :bytes, null: false
      t.binary :data, null: false                        # gzip
      t.string :exception_group_hash, limit: 32          # set when attached to an exception
    end
    add_index :attachments, [ :execution_id ]
    add_index :attachments, [ :exception_group_hash, :occurred_at ]
    add_index :attachments, [ :occurred_at ]

    add_column :outgoing_requests, :response_body, :text  # captured on error only, truncated
    add_column :executions, :profile_id, :integer         # denormalised: the execution has a profile
  end
end
