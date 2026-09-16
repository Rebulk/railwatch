# frozen_string_literal: true

module Railwatch
  module Telemetry
    class IngestBatch < TelemetryRecord
      scope :recent, -> { order(received_at: :desc) }
    end
  end
end
