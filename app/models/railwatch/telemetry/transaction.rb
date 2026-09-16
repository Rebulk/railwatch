# frozen_string_literal: true

module Railwatch
  module Telemetry
    class Transaction < TelemetryRecord
      include Child

      def timeline_label
        outcome.to_s.first(120)
      end
    end
  end
end
