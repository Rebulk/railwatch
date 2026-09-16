# frozen_string_literal: true

module Railwatch
  module Telemetry
    class EnqueuedJob < TelemetryRecord
      include Child

      def timeline_label
        name.to_s.first(120)
      end
    end
  end
end
