# frozen_string_literal: true

module Railwatch
  # A performance rule: "requests to * must keep p95 under 2000 ms over 5
  # minutes". Evaluated by DetectPerformanceIssuesJob against rollups.
  class Threshold < ApplicationRecord
    self.table_name = "railwatch_thresholds"
    MAX_LIMIT = 1_000_000_000
    MAX_WINDOW_MINUTES = 1_440
    TARGET_KINDS = %w[requests jobs commands queries scheduled_tasks outgoing_requests
                      llm_calls llm_tools].freeze
    METRICS = %w[p95 max avg error_rate failure_rate missed spend tokens truncation_rate].freeze

    # Duration and rate metrics read the same on any timed record, so they are
    # allowed everywhere. Money and tokens only mean something where a record
    # carries them: a spend rule on tool calls could never fire, and a rule
    # that cannot fire is worse than no rule -- it reads as coverage.
    SHARED_METRICS = %w[p95 max avg error_rate failure_rate missed].freeze
    LLM_METRICS = %w[spend tokens truncation_rate].freeze

    # Money leads with its symbol; milliseconds and percent follow the number.
    # The old code assumed two units and branched on the metric name ending in
    # "rate", which cannot express a dollar sign in front.
    UNITS = { "spend" => "$", "tokens" => "", "truncation_rate" => "%",
             "error_rate" => "%", "failure_rate" => "%" }.freeze

    def environment = Environment.current

    validates :target_kind, inclusion: { in: TARGET_KINDS }
    validates :metric, inclusion: { in: METRICS }
    validates :limit, numericality: { greater_than: 0, less_than_or_equal_to: MAX_LIMIT }
    validates :window_minutes, numericality: { only_integer: true, greater_than: 0,
                                               less_than_or_equal_to: MAX_WINDOW_MINUTES }
    validates :target, presence: true, length: { maximum: 256 }
    validates :limit, numericality: { less_than_or_equal_to: 100 }, if: -> { metric&.end_with?("rate") }
    validates :target, uniqueness: { scope: %i[environment_id target_kind metric] }
    validate :metric_applies_to_target_kind

    def self.metrics_for(target_kind)
      target_kind == "llm_calls" ? SHARED_METRICS + LLM_METRICS : SHARED_METRICS
    end

    def unit = UNITS.fetch(metric, "ms")

    # "$4.50", "2000ms", "5%", "150000" -- the symbol's position is part of
    # the unit, not something a caller should have to know.
    def format_value(value)
      return "$#{value.is_a?(Float) ? format('%.2f', value) : value}" if unit == "$"

      "#{value}#{unit}"
    end

    def description
      "#{target_kind} #{target == '*' ? 'all' : target}: #{metric} over #{format_value(limit)} in #{window_minutes}m"
    end

    private

    def metric_applies_to_target_kind
      return if metric.blank? || target_kind.blank?
      return if Threshold.metrics_for(target_kind).include?(metric)

      errors.add(:metric, "is not available for #{target_kind}")
    end
  end
end
