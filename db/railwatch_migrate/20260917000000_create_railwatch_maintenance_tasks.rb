# frozen_string_literal: true

# The embedded install's maintenance lease table: one row per task in
# Railwatch::Maintenance::TASKS, recording when it last ran and which process
# holds it now. Lives in the railwatch database with the other permanent,
# operator-facing state rather than in the pruned telemetry file.
class CreateRailwatchMaintenanceTasks < ActiveRecord::Migration[8.1]
  def change
    create_table :railwatch_maintenance_tasks do |t|
      t.string :name, null: false
      t.datetime :last_run_at
      t.string :lease_owner
      t.datetime :lease_expires_at
      t.timestamps
    end
    add_index :railwatch_maintenance_tasks, :name, unique: true
  end
end
