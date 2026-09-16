# frozen_string_literal: true

# Serves the bytes an app attached to an execution or exception. The row
# only exists in its own environment's telemetry database, so an id from
# another environment 404s here.
module Railwatch
    class AttachmentsController < DashboardController
    def show
      attachment = telemetry { Telemetry::Attachment.find(params[:id]) }
      # Rendered as text/plain even for text/html or SVG: these bytes came
      # from a monitored app and must never execute on our origin.
      if params[:view] == "1" && attachment.viewable?
        send_data attachment.body, type: "text/plain; charset=utf-8", disposition: "inline"
      else
        send_data attachment.body, type: attachment.content_type.presence || "application/octet-stream",
          filename: attachment.name, disposition: "attachment"
      end
    rescue Telemetry::BoundedGzip::Error
      head :unprocessable_content
    end
    end
end
