# frozen_string_literal: true

module Railwatch
  module Telemetry
    class CacheEvent < TelemetryRecord
      include Child

      # `type` is the cache operation (hit, miss, write...), not STI.
      self.inheritance_column = nil

      def timeline_label
        "#{type} #{key}".first(120)
      end
    end
  end
end
