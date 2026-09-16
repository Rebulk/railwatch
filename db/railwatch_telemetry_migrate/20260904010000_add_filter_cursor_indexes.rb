# frozen_string_literal: true

# Keyset pagination orders every telemetry list by (sort column, id), so an
# index that stops at the sort column still leaves SQLite sorting ties in a
# temp B-tree. Each index below ends in id for that reason, and exists only
# where the leading filter column is selective enough that seeking beats
# scanning the ordering index and filtering.
#
# Deliberately NOT indexed, even though the FilterBar exposes them:
# exceptions.handled, queries.connection, queries.role, and executions.queue
# all carry a handful of distinct values in practice, so the existing ordering
# index plus a row filter is as good as a seek and costs nothing on write.
class AddFilterCursorIndexes < ActiveRecord::Migration[8.1]
  def change
    # Jobs page, filtered by tenant. index_executions_on_app_tenant_and_occurred_at
    # cannot serve it: the page is already restricted to kind = "job".
    add_index :executions, [ :kind, :app_tenant, :occurred_at, :id ], name: "idx_executions_kind_tenant_cursor"
    # "Failed jobs" is the most-used view on that page and failures are rare,
    # so the two-valued outcome column is highly selective here.
    add_index :executions, [ :kind, :outcome, :occurred_at, :id ], name: "idx_executions_kind_outcome_cursor"

    # exceptions has only (occurred_at); both of these filters are per-tenant
    # or per-class needles in a large table.
    add_index :exceptions, [ :app_tenant, :occurred_at, :id ], name: "idx_exceptions_tenant_cursor"
    add_index :exceptions, [ :class_name, :occurred_at, :id ], name: "idx_exceptions_class_cursor"

    add_index :logs, [ :app_tenant, :occurred_at, :id ], name: "idx_logs_tenant_cursor"
    # Replaced, not added: the same index with the keyset tiebreaker appended.
    remove_index :logs, [ :level, :occurred_at ], name: "index_logs_on_level_and_occurred_at"
    add_index :logs, [ :level, :occurred_at, :id ], name: "idx_logs_level_cursor"

    # The queries page sorts by duration, which index_queries_on_occurred_at_and_duration
    # cannot order by. The first index serves the unfiltered page.
    add_index :queries, [ :duration, :id ], name: "idx_queries_duration_cursor"
    add_index :queries, [ :app_tenant, :duration, :id ], name: "idx_queries_tenant_duration_cursor"
  end
end
