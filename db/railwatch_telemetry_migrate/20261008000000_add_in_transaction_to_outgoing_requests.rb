# frozen_string_literal: true

# An outgoing HTTP call made while the execution held a database transaction
# open: the transaction (and on SQLite with BEGIN IMMEDIATE, the writer lock)
# stays held for the whole round trip. Same meaning as queries.in_transaction.
class AddInTransactionToOutgoingRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :outgoing_requests, :in_transaction, :boolean, default: false
  end
end
