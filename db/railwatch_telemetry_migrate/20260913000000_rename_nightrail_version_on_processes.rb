# frozen_string_literal: true

# The gem version a process reports. Column renamed with the platform; the
# ingest mapper still accepts the pinned lantern gem's wire spelling.
class RenameNightrailVersionOnProcesses < ActiveRecord::Migration[8.1]
  def change
    rename_column :processes, :nightrail_version, :railwatch_version
  end
end
