# frozen_string_literal: true

module Railwatch
  module Telemetry
    class Visit < TelemetryRecord
      include Child

      # Core Web Vitals reported by the browser client, with Google's
      # [good, poor] thresholds: at or below good is "good", above poor is
      # "poor". lcp/inp/ttfb are milliseconds, cls is unitless.
      VITALS = { lcp: [ 2500, 4000 ], cls: [ 0.1, 0.25 ], inp: [ 200, 500 ], ttfb: [ 800, 1800 ] }.freeze

      def self.rating(metric, value)
        good, poor = VITALS.fetch(metric)
        return "good" if value <= good
        (value > poor) ? "poor" : "needs-improvement"
      end

      def timeline_label
        component.to_s.first(120)
      end
    end
  end
end
