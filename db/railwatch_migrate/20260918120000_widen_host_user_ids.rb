# frozen_string_literal: true

# The ids on comments, issue activity, saved views and issue assignment are
# whatever the host's `dashboard_user` resolver returned. They were integer
# columns, which quietly assumed every application numbers its users. An app
# with UUID primary keys could not store a comment at all, and one with ids
# past the signed range could not either.
#
# Nothing joins on these columns and nothing indexes them; they are an opaque
# handle the host gave us and hands back. A string says that, and costs
# nothing in a database that is a few thousand rows of authored content.
#
# Existing values convert cleanly: SQLite rewrites 7 as "7", and the models
# compare with to_s on both sides, so a row written before this migration
# still matches the same viewer after it.
class WidenHostUserIds < ActiveRecord::Migration[8.1]
  COLUMNS = {
    railwatch_issues: :assignee_id,
    railwatch_comments: :viewer_id,
    railwatch_issue_activities: :viewer_id,
    railwatch_saved_views: :viewer_id
  }.freeze

  # SQLite rebuilds a table to change a column type, and a rebuild inside a
  # transaction ignores `PRAGMA foreign_keys = OFF`. This database declares no
  # foreign keys, so there is nothing to cascade, but the rebuild is kept out
  # of the migrator's transaction anyway: it is the cheap half of a habit
  # whose expensive half is deleted rows.
  disable_ddl_transaction!

  def up
    COLUMNS.each do |table, column|
      null = column == :viewer_id && table == :railwatch_saved_views ? false : true
      change_column table, column, :string, limit: 255, null: null
    end
  end

  def down
    COLUMNS.each do |table, column|
      null = column == :viewer_id && table == :railwatch_saved_views ? false : true
      change_column table, column, :integer, null: null
    end
  end
end
