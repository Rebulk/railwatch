# frozen_string_literal: true

module Telemetry
  class StorageOp < TelemetryRecord
    include Child

    def timeline_label
      key.to_s.first(120)
    end
  end
end
