# frozen_string_literal: true

# n_plus_ones had no execution_id index, alone among the child tables, so
# every trace page and every get_route call that asked "which N+1s did
# these requests hit" scanned the table: 1.6 s at 70k rows on the
# platform's own tenant, and it only grows.
class AddNPlusOnesExecutionIdIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :n_plus_ones, :execution_id, name: "index_n_plus_ones_on_execution_id"
  end
end
