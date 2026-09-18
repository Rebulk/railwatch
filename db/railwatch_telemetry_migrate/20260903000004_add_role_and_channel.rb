# frozen_string_literal: true

# Nightwatch parity: a query's multi-DB role (writing/reading) and a
# notification's channel (email/slack/...) alongside the delivery class.
class AddRoleAndChannel < ActiveRecord::Migration[8.1]
  def change
    add_column :queries, :role, :string, limit: 16
    add_column :notifications, :channel, :string, limit: 64
  end
end
