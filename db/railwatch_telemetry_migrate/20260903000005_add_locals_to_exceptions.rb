# frozen_string_literal: true

# Redacted local variables at the raise site, when the gem is configured to
# capture them (NIGHTRAIL_CAPTURE_EXCEPTION_LOCALS).
class AddLocalsToExceptions < ActiveRecord::Migration[8.1]
  def change
    add_column :exceptions, :locals, :json
  end
end
