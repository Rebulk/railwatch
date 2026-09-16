# frozen_string_literal: true

# One row per RubyLLM call: a model call of any operation, or a tool
# invocation (operation "tool", which carries a name and a duration but no
# tokens or cost). Token counts keep RubyLLM's normalized buckets rather
# than a provider's own names, and cost is nanodollars so a month of rollup
# sums stays exact -- nil there means unpriced, never free.
class CreateLlmCalls < ActiveRecord::Migration[8.1]
  def change
    create_table :llm_calls do |t|
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
      t.string :operation, null: false, limit: 20
      t.string :provider, limit: 64
      t.string :model, limit: 255
      t.string :response_model, limit: 255
      t.string :tool_name, limit: 255
      t.integer :duration, null: false
      t.string :status, limit: 16
      t.string :error, limit: 255
      t.boolean :streaming
      t.integer :message_count
      t.integer :tool_count
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :cache_read_tokens
      t.integer :cache_write_tokens
      t.integer :thinking_tokens
      t.bigint :cost_nanos
      # Present only for calls made inside RubyLLM.workflow (2.0 and up).
      # The parent step id is what reconstructs a nested agent run.
      t.string :workflow_id, limit: 64
      t.string :workflow_name, limit: 255
      t.string :workflow_step_id, limit: 64
      t.string :workflow_step_name, limit: 255
      t.string :workflow_step_parent_id, limit: 64
      t.text :prompt
      t.text :completion
    end
    add_index :llm_calls, [ :group_hash, :occurred_at ]
    add_index :llm_calls, [ :execution_id ]
    add_index :llm_calls, [ :workflow_id, :occurred_at ]
  end
end
