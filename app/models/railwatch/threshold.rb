# frozen_string_literal: true

module Railwatch
  # A performance rule: "requests to * must keep p95 under 2000 ms over 5
  # minutes". Evaluated by DetectPerformanceIssuesJob against rollups.
  class Threshold < ApplicationRecord
    MAX_LIMIT = 1_000_000_000
    MAX_WINDOW_MINUTES = 1_440
    TARGET_KINDS = %w[requests jobs commands queries scheduled_tasks outgoing_requests].freeze
    METRICS = %w[p95 max avg error_rate failure_rate missed].freeze

    def environment = Environment.current

    validates :target_kind, inclusion: { in: TARGET_KINDS }
    validates :metric, inclusion: { in: METRICS }
    validates :limit, numericality: { greater_than: 0, less_than_or_equal_to: MAX_LIMIT }
    validates :window_minutes, numericality: { only_integer: true, greater_than: 0,
                                               less_than_or_equal_to: MAX_WINDOW_MINUTES }
    validates :target, presence: true, length: { maximum: 256 }
    validates :limit, numericality: { less_than_or_equal_to: 100 }, if: -> { metric&.end_with?("rate") }
    validates :target, uniqueness: { scope: %i[environment_id target_kind metric] }

    def description
      unit = metric.end_with?("rate") ? "%" : "ms"
      "#{target_kind} #{target == '*' ? 'all' : target}: #{metric} over #{limit}#{unit} in #{window_minutes}m"
    end
  end
end
