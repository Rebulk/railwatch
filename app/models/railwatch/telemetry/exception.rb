# frozen_string_literal: true

module Railwatch
  module Telemetry
    class Exception < TelemetryRecord
      include Child

      self.table_name = "exceptions"

      scope :unhandled, -> { where(handled: false) }

      def as_row
        { id: id, class_name: class_name, message: message.first(500), handled: handled, severity: severity, source: source,
          file: file, line: line, occurred_at: occurred_at, deploy: deploy, execution_id: execution_id,
          execution_source: execution_source, execution_preview: execution_preview, user_ref: user_ref, tenant: app_tenant,
          group_hash: group_hash }
      end

      def timeline_label
        "#{class_name}: #{message.to_s.first(100)}"
      end

      def app_frames
        frames.select { |f| f["in_app"] }
      end
    end
  end
end
