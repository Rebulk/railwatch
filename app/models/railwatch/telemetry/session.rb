# frozen_string_literal: true

module Railwatch
  module Telemetry
    # One session of the monitored application, for release health: a browser
    # tab (reported by the gem's beacon client) or a server-side session (the
    # gem's request middleware). The gem re-sends a live session on every flush
    # interval, so the same session_id arrives many times and gets collapsed to
    # one session per bucket by ReleaseHealthRollupJob.
    class Session < TelemetryRecord
      include Child

      STATUSES = %w[started ok errored crashed].freeze

      def crashed?
        status == "crashed"
      end

      def timeline_label
        session_id
      end
    end
  end
end
