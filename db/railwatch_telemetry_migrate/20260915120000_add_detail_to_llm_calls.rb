# frozen_string_literal: true

# What an LLM call carried and how it was configured, alongside what it
# cost. finish_reason is the one that changes what you can see: max_tokens
# means the answer was cut off, and a truncated extraction otherwise reads
# exactly like a complete one.
class AddDetailToLlmCalls < ActiveRecord::Migration[8.1]
  def change
    change_table :llm_calls, bulk: true do |t|
      t.string :finish_reason, limit: 32
      t.string :provider_request_id, limit: 128
      t.string :tools, limit: 1024
      t.boolean :cost_reported
      t.integer :attachments
      t.string :attachment_types, limit: 128
      t.string :attachment_names, limit: 1024
      t.string :tool_call_id, limit: 128
      t.json :params
    end
  end
end
