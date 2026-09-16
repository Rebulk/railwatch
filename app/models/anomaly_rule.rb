# frozen_string_literal: true

# "Alert when p95 of GET /checkout is more than 3 standard deviations above
# its 7-day baseline for the same time of day." Evaluated by
# DetectAnomaliesJob against hourly rollups.
class AnomalyRule < RailwatchRecord
  MIN_BASELINE_DAYS = 3
  MAX_BASELINE_DAYS = 30
  MAX_DEVIATION = 10
  MAX_WINDOW_MINUTES = 1_440
  TARGET_KINDS = %w[requests jobs queries outgoing_requests scheduled_tasks].freeze
  METRICS = %w[p95 avg count error_rate].freeze

  def environment = ::Environment.current

  validates :target_kind, inclusion: { in: TARGET_KINDS }
  validates :metric, inclusion: { in: METRICS }
  validates :target, presence: true, length: { maximum: 256 }
  validates :deviation, numericality: { greater_than: 0, less_than_or_equal_to: MAX_DEVIATION }
  validates :window_minutes, numericality: { only_integer: true, greater_than: 0,
                                             less_than_or_equal_to: MAX_WINDOW_MINUTES }
  validates :baseline_days, numericality: { only_integer: true, greater_than_or_equal_to: MIN_BASELINE_DAYS,
                                            less_than_or_equal_to: MAX_BASELINE_DAYS }

  scope :enabled, -> { where(enabled: true) }

  def description
    "#{target_kind} #{target == '*' ? 'all' : target}: #{metric} > #{deviation}σ above #{baseline_days}-day baseline"
  end
end
