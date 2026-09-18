# frozen_string_literal: true

module Railwatch
  module Telemetry
    # A file an app attached to an execution or exception with Railwatch.attach.
    # `data` is gzip of the original bytes.
    class Attachment < TelemetryRecord
      include Child

      # A record has to fit inside the API's decoded request ceiling. Keeping
      # the per-attachment ceiling equal to it preserves every valid existing
      # payload while bounding reads of legacy rows.
      MAX_BODY_BYTES = IngestRequestBodyLimit::MAX_BYTES

      def body
        BoundedGzip.decompress(data, max_bytes: MAX_BODY_BYTES)
      end

      # Only text-ish payloads are safe to render in the browser; everything
      # else downloads. Rendered as text/plain either way, so a stored
      # text/html attachment can never execute against our origin.
      def viewable?
        content_type.to_s.start_with?("text/") || content_type.to_s.split(";").first == "application/json"
      end

      def timeline_label
        name.to_s.first(120)
      end
    end
  end
end
