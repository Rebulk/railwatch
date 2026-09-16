# frozen_string_literal: true

module Railwatch
  # Evaluates every threshold for an environment against the last window of
  # rollups and opens performance issues. Runs on a schedule (recurring.yml).
  class DetectPerformanceIssuesJob < ApplicationJob
    include DetectionSnapshotting

    queue_as :default

    MAX_GROUPS_PER_RULE = 200
    MAX_ROLLUP_ROWS_PER_RULE = MAX_GROUPS_PER_RULE * 25

    TYPE_FOR = { "requests" => "request", "jobs" => "job_attempt", "commands" => "command", "queries" => "query",
                 "scheduled_tasks" => "scheduled_task", "outgoing_requests" => "outgoing_request" }.freeze

    def perform(environment)
      now = Time.current
      environment.thresholds.find_each do |threshold|
        from = now - threshold.window_minutes.minutes
        type = TYPE_FOR.fetch(threshold.target_kind)
        groups = environment.with_telemetry do
          scope = Telemetry::Rollup.for_type(type).between(from, now)
          scope = scope.where(name: threshold.target) unless threshold.target == "*"
          bounded_groups(scope, threshold)
        end
        groups.each do |group_hash, (name, summary)|
          value = value_for(threshold.metric, summary)
          next if value.nil? || value <= threshold.limit
          open_issue(environment, threshold, group_hash, name, value, from, now)
        end
      end
    end

    private

    def bounded_groups(scope, threshold)
      group_hashes = scope.reorder(nil).group(:group_hash).order(Arel.sql("SUM(count) DESC"), :group_hash)
                          .limit(MAX_GROUPS_PER_RULE + 1).pluck(:group_hash)
      if group_hashes.length > MAX_GROUPS_PER_RULE
        Rails.logger.warn("threshold detector evaluated only the #{MAX_GROUPS_PER_RULE} busiest groups threshold_id=#{threshold.id}")
        group_hashes.pop
      end
      rows = scope.where(group_hash: group_hashes).order(:bucket, :group_hash).limit(MAX_ROLLUP_ROWS_PER_RULE + 1).to_a
      if rows.length > MAX_ROLLUP_ROWS_PER_RULE
        Rails.logger.error("threshold detector skipped threshold_id=#{threshold.id}: more than #{MAX_ROLLUP_ROWS_PER_RULE} rollups")
        return {}
      end

      rows.group_by(&:group_hash)
          .transform_values { |group_rows| [ group_rows.first.name, Telemetry::Rollup.summarize(group_rows) ] }
    end

    def value_for(metric, s)
      case metric
      when "p95" then s[:p95] / 1000.0
      when "max" then s[:max] / 1000.0
      when "avg" then s[:avg] / 1000.0
      when "error_rate", "failure_rate" then s[:count].zero? ? nil : (s[:errors] * 100.0 / s[:count])
      end
    end

    def open_issue(environment, threshold, group_hash, name, value, from, now)
      issue, outcome = Issue.record_occurrence!(
        environment: environment, group_hash: "perf:#{threshold.id}:#{group_hash}", kind: "performance",
        title: "#{name} exceeded #{threshold.metric} #{threshold.limit}#{threshold.metric.end_with?('rate') ? '%' : 'ms'} (#{value.round(1)})",
        culprit: name, occurred_at: now, deploy: nil, user_ref: nil,
        sample: { threshold_id: threshold.id, value: value.round(2), metric: threshold.metric, limit: threshold.limit })
      carry_detection(issue, outcome) do
        IssueDetectionSnapshot.capture(
          environment: environment, kind: "performance", telemetry_type: TYPE_FOR.fetch(threshold.target_kind),
          telemetry_group_hash: group_hash, target: name, metric: threshold.metric, from: from, to: now,
          value: value.round(2), limit: threshold.limit,
          rule: { type: "threshold", id: threshold.id, target_kind: threshold.target_kind, target: threshold.target }
        )
      end
      return unless outcome == :new || outcome == :regressed
      payload = { issue_key: issue.key, title: issue.title, environment: environment.name }
      environment.application.alert_rules.where(event: "threshold").find_each do |rule|
        next unless rule.matches?(issue: issue, payload: payload)
        rule.fire!(event: "threshold", issue: issue, payload: payload)
      end
    end
  end
end
