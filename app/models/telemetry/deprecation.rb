# frozen_string_literal: true

module Telemetry
  class Deprecation < TelemetryRecord
    include Child

    def timeline_label
      message.to_s.first(120)
    end
  end
end
