# frozen_string_literal: true

module Railwatch
  module Telemetry
    class Broadcast < TelemetryRecord
      include Child

      def timeline_label
        stream.to_s.first(120)
      end
    end
  end
end
