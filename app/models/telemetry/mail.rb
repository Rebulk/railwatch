# frozen_string_literal: true

module Telemetry
  class Mail < TelemetryRecord
    include Child

    def timeline_label
      mailer.to_s.first(120)
    end
  end
end
