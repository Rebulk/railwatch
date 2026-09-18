# frozen_string_literal: true

# Whether a channel action raised. The gem reports the exception itself
# (source "application.action_cable"); this flag lets the Broadcasts page mark
# the failed action alongside its siblings, the way jobs and mail already do.
class AddFailedToBroadcasts < ActiveRecord::Migration[8.1]
  def change
    add_column :broadcasts, :failed, :boolean, default: false, null: false
  end
end
