# frozen_string_literal: true

module Railwatch
  module Telemetry
    # A custom span recorded with Railwatch.span("name") { }, a child of the
    # request/job/command it ran inside.
    class Span < TelemetryRecord
      include Child

      scope :failed, -> { where(status: "failed") }

      # The wire record calls the user payload "attributes"; the column is
      # `payload` because `attributes` is Active Record's own method.
      def timeline_label
        name.to_s.first(120)
      end
    end
  end
end
