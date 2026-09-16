# frozen_string_literal: true

module Railwatch
  module Telemetry
    class OutgoingRequest < TelemetryRecord
      include Child

      def timeline_label
        url.to_s.first(120)
      end
    end
  end
end
