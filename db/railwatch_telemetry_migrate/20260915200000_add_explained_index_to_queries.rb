# frozen_string_literal: true

# The queries page asks "which of these 200 shapes have a captured plan in
# the window?" -- WHERE occurred_at BETWEEN ? AND ? AND group_hash IN (200
# values) AND explain IS NOT NULL. The planner walks the (group_hash,
# occurred_at) index for every one of the 200 shapes and then checks
# `explain` on each row, which is 840 ms at one day of one environment's
# queries (1M rows), and that whole time is a GVL hold: sqlite3-ruby does
# not release the GVL inside sqlite3_step. Plans are only captured for slow
# queries, so a partial index over just the explained rows is tiny and
# answers the question in 4 ms.
class AddExplainedIndexToQueries < ActiveRecord::Migration[8.1]
  def change
    add_index :queries, [ :group_hash, :occurred_at ], name: "idx_queries_explained", where: "explain IS NOT NULL"
  end
end
