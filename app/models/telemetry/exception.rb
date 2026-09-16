# frozen_string_literal: true

module Telemetry
  class Exception < TelemetryRecord
    include Child

    self.table_name = "exceptions"

    scope :unhandled, -> { where(handled: false) }

    def timeline_label
      "#{class_name}: #{message.to_s.first(100)}"
    end

    def app_frames
      frames.select { |f| f["in_app"] }
    end
  end
end
