# frozen_string_literal: true

# Two dashboard aggregates read every row in the window and only a few
# narrow columns of each: the Jobs page's per-queue breakdown and the
# Processes page's health series. Through (kind, occurred_at) and
# (sampled_at) SQLite finds the rows in order but then fetches each one
# from the table, and on a telemetry file much larger than memory those
# rows are scattered pages on disk. On the platform's own 30 GB tenant,
# over a week: 38 s for the queue breakdown (491,000 job attempts) and
# 19 s for the health series (263,000 samples), with the GVL held the
# whole time, so every other request in the process waited too.
#
# Both indexes carry every column their query reads, so the whole answer
# comes from one contiguous index range: 335 ms and 370 ms on a copy of
# the same file. They cost 151 MB and 29 MB there, and took 13 s and 2 s
# to build.
#
# broadcasts is the one windowed table with no index led by occurred_at,
# so the Broadcasts page's "recent" list sorted the whole window to show
# 100 rows. Every other raw table has had this index since it was created.
#
# Free-text search over jobs and requests also matches the exception
# preview, which only a failed execution carries (15 of 491,000 job
# attempts in that same week). A partial index over just those rows lets
# Execution.named_like seek them instead of reading the window.
class AddCoveringIndexesForDashboardAggregates < ActiveRecord::Migration[8.1]
  def change
    add_index :executions, [ :kind, :occurred_at, :queue, :outcome, :queue_latency ], name: "idx_executions_queue_stats"
    add_index :health_samples, [ :sampled_at, :threads_max, :threads_busy, :backlog, :queue_depth, :queue_latency ],
              name: "idx_health_samples_series"
    add_index :broadcasts, :occurred_at
    add_index :executions, [ :kind, :occurred_at ], name: "idx_executions_with_preview", where: "exception_preview IS NOT NULL"
  end
end
