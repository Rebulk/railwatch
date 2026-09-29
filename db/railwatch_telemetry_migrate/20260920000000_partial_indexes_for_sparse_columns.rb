# frozen_string_literal: true

# Three indexes over columns that are NULL on nearly every row. SQLite indexes
# NULLs like any other key, so each one carries a full-size B-tree entry per
# row that has nothing to find. An app that never calls Railwatch.context or
# Railwatch.user has no non-NULL rows at all: on a 40,000-execution extract of
# one such database, 144,196 query rows carry no tenant, 39,912 executions no
# user and 38,736 no parent, and the three indexes hold 4.12 MiB between them.
#
# A partial index skips those rows, and SQLite still uses it for every
# predicate that implies its WHERE clause -- `col = ?` and `col IS NOT NULL`
# both do -- so the plans for the person page (people_controller.rb:19), the
# people aggregate (people_controller.rb:8) and the user filter
# (filter_query.rb:87) are unchanged. An app that does tag its telemetry saves
# less and loses nothing: measured against a second extract whose query rows
# are 83% tenant-tagged, the same three indexes still gave back 3.81 MiB, and
# a partial index is never larger than the full one it replaces.
#
# Deliberately NOT made partial: index_executions_on_app_tenant_and_occurred_at.
# telemetry/tenant.rb:50 counts untagged requests with `where(app_tenant: nil)`,
# which a `WHERE app_tenant IS NOT NULL` index cannot serve.
class PartialIndexesForSparseColumns < ActiveRecord::Migration[8.1]
  def change
    # The queries page reaches this one through filter_query.rb:88, though
    # CursorPage forces idx_queries_slowest for that page (cursor_page.rb:35),
    # so in practice the planner is never offered the choice.
    remove_index :queries, [ :app_tenant, :duration, :id ], name: "idx_queries_tenant_duration_cursor"
    add_index :queries, [ :app_tenant, :duration, :id ], name: "idx_queries_tenant_duration_cursor",
              where: "app_tenant IS NOT NULL"

    remove_index :executions, [ :user_ref, :occurred_at ], name: "index_executions_on_user_ref_and_occurred_at"
    add_index :executions, [ :user_ref, :occurred_at ], name: "index_executions_on_user_ref_and_occurred_at",
              where: "user_ref IS NOT NULL"

    # Nothing reads this column through a WHERE: TracesController loads a trace
    # by trace_id and matches parents in Ruby (traces_controller.rb:39), so
    # there is no plan to change here, only 97% fewer entries to write.
    remove_index :executions, :parent_id, name: "index_executions_on_parent_id"
    add_index :executions, :parent_id, name: "index_executions_on_parent_id", where: "parent_id IS NOT NULL"
  end
end
