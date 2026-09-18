# frozen_string_literal: true

# The queries page's "slowest in window" list orders the window by duration
# and takes a page. Every existing index leads with occurred_at, so the
# planner scans the whole window and sorts it: 48 ms for a day of one
# environment's queries (1M rows) -- and sqlite3-ruby holds the GVL for the
# whole statement, so every other request thread waits too. An index that
# leads with (duration DESC, id DESC) matches the page's ORDER BY exactly, so
# SQLite walks it from the slowest row and stops at the page (microseconds,
# and it cannot get worse as the table grows); occurred_at rides along so
# the window filter is answered from the index too. The planner still
# prefers the occurred_at index on its own cost model, so CursorPage forces
# this one.
class AddSlowestIndexToQueries < ActiveRecord::Migration[8.1]
  def change
    add_index :queries, [ :duration, :id, :occurred_at ], name: "idx_queries_slowest", order: { duration: :desc, id: :desc }
  end
end
