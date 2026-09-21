# frozen_string_literal: true

# How much of an execution's tree the gem threw away before it shipped: the
# per-execution buffer (execution_buffer_bytes) keeps the earliest records
# and drops the rest, and until now the parent said nothing about it. A job
# that issued 5,000 queries showed a plausible 3,000-query trace. Null on
# rows written by an older gem; absent from the wire when nothing was lost.
class AddDroppedToExecutions < ActiveRecord::Migration[8.1]
  def change
    change_table :executions, bulk: true do |t|
      t.integer :dropped_records
      t.bigint :dropped_bytes
    end
  end
end
