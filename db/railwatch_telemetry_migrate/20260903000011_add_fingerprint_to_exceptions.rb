# frozen_string_literal: true

# The parts the gem hashed this exception into an issue on, and where they
# came from (its own default, a resolver, a per-call fingerprint, or the
# error class itself) -- so an issue can show why it grouped the way it did.
class AddFingerprintToExceptions < ActiveRecord::Migration[8.1]
  def change
    add_column :exceptions, :fingerprint, :json, default: [], null: false
    add_column :exceptions, :fingerprint_source, :string, limit: 16
  end
end
