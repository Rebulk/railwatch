# frozen_string_literal: true

# The gem reports when load forces it to sample every execution kind, so the
# platform can distinguish quiet traffic from reduced client-side reporting.
class AddBackpressureFactorToIngestBatches < ActiveRecord::Migration[8.1]
  def change
    add_column :ingest_batches, :backpressure_factor, :float, null: false, default: 1.0
  end
end
