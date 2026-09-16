# frozen_string_literal: true

# Compares each enabled anomaly rule's current window against the same clock
# window on each of the previous `baseline_days` days and opens an anomaly
# issue when the current value sits above the baseline's mean plus
# `deviation` standard deviations. Runs on a schedule via AnomalyScanJob.
class DetectAnomaliesJob < ApplicationJob
  include DetectionSnapshotting

  queue_as :default

  TYPE_FOR = DetectPerformanceIssuesJob::TYPE_FOR
  # Fewer baseline days than this and the standard deviation is noise.
  MIN_BASELINE_DAYS = AnomalyRule::MIN_BASELINE_DAYS
  # Volume metrics on a handful of events swing wildly; ignore them.
  MIN_EVENTS = 20
  COOL_DOWN = 60.minutes
  MAX_GROUPS_PER_RULE = 50
  MAX_CURRENT_ROWS_PER_RULE = MAX_GROUPS_PER_RULE * 25
  MAX_BASELINE_ROWS_PER_RULE = 50_000

  def perform(environment)
    now = Time.current
    environment.anomaly_rules.enabled.find_each do |rule|
      detect(environment, rule, now).each { |detection| open_issue(environment, rule, now, detection) }
    end
  end

  private

  def detect(environment, rule, now)
    from = now - rule.window_minutes.minutes
    type = TYPE_FOR.fetch(rule.target_kind)
    environment.with_telemetry do
      groups = current_groups(rule, type, from, now)
      baseline = baseline_rows(rule, type, groups.keys, from, now)
      return [] unless baseline

      groups.filter_map do |group_hash, (name, summary)|
        anomaly_for(rule, group_hash, name, summary, baseline.fetch(group_hash, []), from, now)
      end
    end
  end

  # Rollups are hourly, so a window shorter than an hour reads the whole
  # enclosing hour bucket (Rollup.between rounds `from` down); the baseline
  # windows are shifted by whole days and land on the same hour, so the
  # comparison stays like-for-like.
  def current_groups(rule, type, from, to)
    scope = Telemetry::Rollup.for_type(type).between(from, to)
    scope = scope.where(name: rule.target) unless rule.target == "*"
    group_hashes = scope.reorder(nil).group(:group_hash).order(Arel.sql("SUM(count) DESC"), :group_hash)
                        .limit(MAX_GROUPS_PER_RULE + 1).pluck(:group_hash)
    if group_hashes.length > MAX_GROUPS_PER_RULE
      Rails.logger.warn("anomaly detector evaluated only the #{MAX_GROUPS_PER_RULE} busiest groups rule_id=#{rule.id}")
      group_hashes.pop
    end
    rows = scope.where(group_hash: group_hashes).order(:bucket, :group_hash).limit(MAX_CURRENT_ROWS_PER_RULE + 1).to_a
    if rows.length > MAX_CURRENT_ROWS_PER_RULE
      Rails.logger.error("anomaly detector skipped rule_id=#{rule.id}: more than #{MAX_CURRENT_ROWS_PER_RULE} current rollups")
      return {}
    end

    rows.group_by(&:group_hash)
        .transform_values { |group_rows| [ group_rows.first.name, Telemetry::Rollup.summarize(group_rows) ] }
  end

  def anomaly_for(rule, group_hash, name, summary, baseline_rows, from, to)
    return if cooling_down?(rule, group_hash)
    current = value_for(rule.metric, summary, rule.window_minutes)
    return if current.nil?
    return if %w[count error_rate].include?(rule.metric) && summary[:count] < MIN_EVENTS

    baseline = baseline_values(rule, baseline_rows, from, to)
    return if baseline.size < MIN_BASELINE_DAYS
    mean = baseline.sum / baseline.size
    stddev = Math.sqrt(baseline.sum { |v| (v - mean)**2 } / baseline.size)
    return unless current > mean + (rule.deviation * stddev) && current > mean * 1.25

    # A perfectly flat baseline has no σ to measure against, so report the
    # rule's own threshold rather than an infinite one.
    sigmas = stddev.positive? ? (current - mean) / stddev : rule.deviation
    { group_hash: group_hash, name: name, current: current.round(2), mean: mean.round(2),
      stddev: stddev.round(2), sigmas: sigmas.round(2) }
  end

  # The same clock window on each of the previous `baseline_days` days. Days
  # with no rollups at all are left out rather than counted as zero.
  def baseline_values(rule, rows, from, to)
    (1..rule.baseline_days).filter_map do |days|
      day_rows = rows.select { |row| row.bucket.between?((from - days.days).beginning_of_hour, to - days.days) }
      next if day_rows.empty?
      value_for(rule.metric, Telemetry::Rollup.summarize(day_rows), rule.window_minutes)
    end
  end

  # One query for every group's baseline, reading only the hour buckets the
  # baseline windows actually cover rather than the whole `baseline_days` span.
  def baseline_rows(rule, type, group_hashes, from, to)
    return {} if group_hashes.empty?

    rows = Telemetry::Rollup.for_type(type)
             .where(group_hash: group_hashes, bucket: baseline_buckets(rule, from, to))
             .order(:bucket, :group_hash).limit(MAX_BASELINE_ROWS_PER_RULE + 1).to_a
    if rows.length > MAX_BASELINE_ROWS_PER_RULE
      Rails.logger.error("anomaly detector skipped rule_id=#{rule.id}: more than #{MAX_BASELINE_ROWS_PER_RULE} baseline rollups")
      return nil
    end
    rows.group_by(&:group_hash)
  end

  # The hour buckets covered by the same clock window on each of the previous
  # `baseline_days` days.
  def baseline_buckets(rule, from, to)
    (1..rule.baseline_days).flat_map do |days|
      bucket = (from - days.days).beginning_of_hour
      last = to - days.days
      buckets = []
      while bucket <= last
        buckets << bucket
        bucket += 1.hour
      end
      buckets
    end
  end

  def value_for(metric, summary, window_minutes)
    case metric
    when "p95" then summary[:p95] / 1000.0
    when "avg" then summary[:avg] / 1000.0
    when "count" then summary[:count] / window_minutes.to_f
    when "error_rate" then summary[:count].zero? ? nil : (summary[:errors] * 100.0 / summary[:count])
    end
  end

  # Reads the primary database: one open anomaly issue per (rule, group) is
  # enough for an hour, however often the scan runs.
  def cooling_down?(rule, group_hash)
    Issue.where(environment_id: rule.environment_id, group_hash: issue_group_hash(rule, group_hash))
         .where(last_seen_at: COOL_DOWN.ago..).exists?
  end

  def issue_group_hash(rule, group_hash)
    "anomaly:#{rule.id}:#{group_hash}"
  end

  def open_issue(environment, rule, now, detection)
    issue, outcome = Issue.record_occurrence!(
      environment: environment, group_hash: issue_group_hash(rule, detection[:group_hash]), kind: "anomaly",
      title: "#{rule.metric} of #{detection[:name]} is #{detection[:sigmas].round(1)}σ above its #{rule.baseline_days}-day baseline (#{detection[:current]} vs #{detection[:mean]})",
      culprit: detection[:name], occurred_at: now, deploy: nil, user_ref: nil,
      sample: { rule_id: rule.id, metric: rule.metric, current: detection[:current], mean: detection[:mean],
                stddev: detection[:stddev], sigmas: detection[:sigmas], window_minutes: rule.window_minutes })
    carry_detection(issue, outcome) do
      IssueDetectionSnapshot.capture(
        environment: environment, kind: "anomaly", telemetry_type: TYPE_FOR.fetch(rule.target_kind),
        telemetry_group_hash: detection[:group_hash], target: detection[:name], metric: rule.metric,
        from: now - rule.window_minutes.minutes, to: now, value: detection[:current],
        baseline: detection.slice(:mean, :stddev, :sigmas).merge(days: rule.baseline_days, deviation: rule.deviation),
        rule: { type: "anomaly", id: rule.id, target_kind: rule.target_kind, target: rule.target }
      )
    end
    if outcome == :new || outcome == :regressed
      issue.fire_alerts!("anomaly", rule_id: rule.id, metric: rule.metric, current: detection[:current],
        mean: detection[:mean], sigmas: detection[:sigmas])
    end
    rule.update_columns(last_fired_at: now)
  end
end
