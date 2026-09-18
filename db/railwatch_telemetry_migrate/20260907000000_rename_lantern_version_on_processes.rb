# frozen_string_literal: true

# The gem version a process reports. Column renamed with the platform; the
# ingest mapper accepts both wire spellings while environments still run the
# lantern gem.
class RenameLanternVersionOnProcesses < ActiveRecord::Migration[8.1]
  def change
    rename_column :processes, :lantern_version, :nightrail_version
  end
end
