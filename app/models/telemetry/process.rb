# frozen_string_literal: true

module Telemetry
  class Process < TelemetryRecord
    self.table_name = "processes"
    scope :recent, -> { order(booted_at: :desc) }
  end
end
