# frozen_string_literal: true

module Railwatch
  # Refreshes SQLite's planner statistics for each environment's telemetry
  # database. Nothing else ever runs ANALYZE on these files, so the planner
  # has been choosing index shapes blind on tables that grow by hundreds of
  # thousands of rows a day. PRAGMA optimize only re-analyzes tables whose
  # stats look stale, so it is cheap to run daily; analysis_limit bounds the
  # rows it samples per index.
  class OptimizeTelemetryJob < ApplicationJob
    queue_as :maintenance

    def perform(environment = nil)
      return [ Environment.current ].each { |env| self.class.perform_later(env) } if environment.nil?

      environment.with_telemetry do
        connection = TelemetryRecord.connection
        connection.execute("PRAGMA analysis_limit = 1000")
        connection.execute("PRAGMA optimize")
      end
    end
  end
end
