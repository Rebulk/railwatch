# frozen_string_literal: true

module Railwatch
  module Telemetry
    class Notification < TelemetryRecord
      include Child

      def timeline_label
        notifier.to_s.first(120)
      end
    end
  end
end
