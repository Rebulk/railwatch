# frozen_string_literal: true

# The People page groups the window's signed-in requests by user_ref.
# Through (user_ref, occurred_at) SQLite found those rows but fetched each
# one from the table for kind and status: 4 s over 30 days on the
# platform's own tenant, where 18,000 of 2.8 million executions carry a
# user. This index holds every column the query reads, and only for rows
# that have a user, so it answers in 18 ms from under a megabyte. It took
# 10 s to build on a copy of that 30 GB file.
class AddPeopleIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :executions, [ :user_ref, :kind, :occurred_at, :status ], name: "idx_executions_people",
              where: "user_ref IS NOT NULL"
  end
end
