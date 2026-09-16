# frozen_string_literal: true

# The gem reports how many statements ran inside each transaction; the
# ingest mapper dropped it because the column never existed.
class AddStatementCountToTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :transactions, :statement_count, :integer
  end
end
