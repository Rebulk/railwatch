# frozen_string_literal: true

module Telemetry
  class ViewRender < TelemetryRecord
    include Child

    def timeline_label
      identifier.to_s.first(120)
    end
  end
end
