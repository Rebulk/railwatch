# frozen_string_literal: true

# A query group's normalized statement, stored once; rows that carry
# exactly it store "" instead (docs/architecture.md). queries.sql keeps
# its NOT NULL: relaxing it would rewrite the table on every tenant, which
# SQLite cannot do in place and the deploy's health window cannot afford.
class CreateQueryShapes < ActiveRecord::Migration[8.1]
  def change
    create_table :query_shapes, id: false do |t|
      t.string :group_hash, null: false, limit: 32
      t.text :sql, null: false
    end
    add_index :query_shapes, :group_hash, unique: true
  end
end
