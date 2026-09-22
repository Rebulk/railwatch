# frozen_string_literal: true

module Railwatch
  # Overview triage uses persisted issues and a bounded health snapshot. It
  # never runs detectors or scans raw telemetry while rendering the page.
  class Attention
    LIMIT = 8
    HEALTH_LIMIT = 3
    PRIORITY_ORDER = "CASE priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'normal' THEN 2 ELSE 3 END"
    UNITS = IssueDetectionSnapshot::UNITS.merge("spend" => "usd", "tokens" => "tokens", "truncation_rate" => "percent").freeze

    def initialize(environment, from:, to:, health:)
      @environment, @from, @to, @health = environment, from, to, health
    end

    def to_h
      open = @environment.issues.open
      @issue_prefix = @environment.application.issue_prefix
      recent = open.where(last_seen_at: @from..@to)
      health_items = @health.fetch(:attention).sort_by { |item| [ item[:severity] == "critical" ? 0 : 1, item[:key] ] }
        .map { |item| item.merge(id: "health:#{item[:key]}", type: "health") }
      if @health[:status] == "unknown"
        health_items << { id: "health:unknown", type: "health", severity: "unknown", title: "Monitoring evidence is incomplete",
                          detail: "Some monitoring checks have no recorded evidence. Review monitoring health before relying on an empty issue list." }
      end
      shown_health = health_items.first(HEALTH_LIMIT)
      issues = recent.reorder(Arel.sql(PRIORITY_ORDER)).order(affected_users: :desc, last_seen_at: :desc, id: :asc)
        .limit(LIMIT - shown_health.length).map { |issue| issue_item(issue) }
      { open_issue_count: open.count, recent_issue_count: recent.count, health_count: health_items.length,
        health_status: @health[:status], checked_at: @health[:checked_at],
        from: @from, to: @to, items: shown_health + issues }
    end

    private

    def issue_item(issue)
      sample = issue.sample.is_a?(Hash) ? issue.sample : {}
      { id: "issue:#{issue.id}", type: "issue", issue_id: issue.id, key: "#{@issue_prefix}-#{issue.number}", title: issue.title,
        kind: issue.kind, priority: issue.priority, occurrences: issue.occurrences, affected_users: issue.affected_users,
        last_seen_at: issue.last_seen_at, regressed: issue.regressed_at.present? && (@from..@to).cover?(issue.regressed_at),
        evidence: detection_evidence(sample["detection"], issue.kind), deploy: sample["deploy"].is_a?(String) ? sample["deploy"].first(80) : nil }
    end

    def detection_evidence(snapshot, kind)
      return unless snapshot.is_a?(Hash) && snapshot["schema_version"] == 1
      return unless %w[performance anomaly].include?(kind) && snapshot["kind"] == kind
      unit = UNITS[snapshot["metric"]]
      return unless unit && unit != "schedule" && unit == snapshot["unit"]

      window = snapshot["window"]
      return unless window.is_a?(Hash)
      from, to = [ window["from"], window["to"] ].map { |value| Time.iso8601(value) if value.is_a?(String) && value.length <= 64 }
      return unless from && to && to > from && to >= @from && from <= @to

      measurement = snapshot["measurement"].is_a?(Hash) ? snapshot["measurement"] : {}
      baseline = snapshot["baseline"].is_a?(Hash) ? snapshot["baseline"] : {}
      value = number(measurement["value"], unit)
      return unless value
      limit = number(measurement["limit"], unit)
      mean = number(baseline["mean"], unit)
      return if measurement.key?("limit") && (!limit || !limit.positive?)
      return if baseline.key?("mean") && !mean

      { metric: snapshot["metric"], unit: unit, value: value, limit: limit, baseline_mean: mean, from: from, to: to }
    rescue ArgumentError
      nil
    end

    def number(value, unit)
      value if value.is_a?(Numeric) && value.finite? && value >= 0 && (unit != "percent" || value <= 100)
    end
  end
end
