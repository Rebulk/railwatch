# frozen_string_literal: true

module Railwatch
  # Builds the same discriminated performance/anomaly detail contract for the
  # Inertia page, REST API, and MCP. The durable detector snapshot remains useful
  # after raw data is pruned; live rollups add trend and deploy comparison when
  # they are still available.
  class IssueDetectionPresenter
    TREND_DAYS = 30
    DEPLOY_LIMIT = 20
    EXECUTION_TYPES = IssueDetectionSnapshot::EXECUTION_TYPES
    SCHEMA_VERSION = 1
    NUMERIC_FIELDS = {
      "measurement" => %w[value limit],
      "baseline" => %w[mean stddev sigmas days deviation]
    }.freeze
    RULE_STRING_FIELDS = %w[type target_kind target task_key schedule last_run expected].freeze
    EXECUTION_SOURCES = %w[request job job_attempt scheduled_task command].freeze
    CHILD_TYPES = %w[query outgoing_request].freeze
    TARGET_KIND_FOR = {
      "request" => "requests", "job_attempt" => "jobs", "command" => "commands",
      "query" => "queries", "scheduled_task" => "scheduled_tasks",
      "outgoing_request" => "outgoing_requests"
    }.freeze

    def initialize(issue)
      @issue = issue
      @details = issue.sample["detection"]
    end

    def as_json
      return unless @issue.kind.in?(%w[performance anomaly])
      return unavailable_json unless @details.is_a?(Hash)

      validate_details!
      live = @issue.environment.with_telemetry { live_details }
      @details.deep_symbolize_keys.merge(
        available: true,
        count_label: "Breached evaluation windows",
        breached_windows: @issue.occurrences,
        event_count: live[:event_count],
        trend: live[:trend],
        deploy_comparison: live[:deploy_comparison],
        representative_references: representative_references,
        representative_records: representatives
      )
    rescue KeyError, ArgumentError, TypeError
      unavailable_json
    end

    private

    def unavailable_json
      {
        kind: @issue.kind, available: false,
        count_label: "Breached evaluation windows", breached_windows: @issue.occurrences,
        message: "Typed detector context was not captured for this historical issue."
      }
    end

    def validate_details!
      raise ArgumentError unless @details.fetch("schema_version") == SCHEMA_VERSION
      raise ArgumentError unless @details.fetch("kind") == @issue.kind
      telemetry_type = @details.fetch("telemetry_type")
      raise ArgumentError unless telemetry_type.in?(EXECUTION_TYPES + %w[query outgoing_request])
      target_kind = TARGET_KIND_FOR.fetch(telemetry_type)
      allowed_target_kinds = @issue.kind == "anomaly" ? AnomalyRule::TARGET_KINDS : Threshold::TARGET_KINDS
      raise ArgumentError unless target_kind.in?(allowed_target_kinds)
      %w[telemetry_group_hash target metric unit].each do |key|
        raise ArgumentError unless @details.fetch(key).is_a?(String) && @details.fetch(key).present?
      end
      metric = @details.fetch("metric")
      allowed_metrics = @issue.kind == "anomaly" ? AnomalyRule::METRICS : Threshold::METRICS
      raise ArgumentError unless metric.in?(allowed_metrics)
      raise ArgumentError if metric == "missed" && @details.fetch("telemetry_type") != "scheduled_task"
      expected_unit = IssueDetectionSnapshot::UNITS[metric]
      raise ArgumentError unless expected_unit && @details.fetch("unit") == expected_unit
      validate_window!
      NUMERIC_FIELDS.each { |key, fields| validate_numeric_object!(key, fields) }
      validate_rule!
      validate_detector_shape!
      validate_representatives!
    end

    def validate_window!
      window = @details.fetch("window")
      raise ArgumentError unless window.is_a?(Hash)
      from = Time.iso8601(window.fetch("from"))
      to = Time.iso8601(window.fetch("to"))
      minutes = window.fetch("minutes")
      raise ArgumentError unless finite_number?(minutes) && minutes.positive? && to > from
      raise ArgumentError unless (minutes - ((to - from) / 60.0).round(2)).abs <= 0.01
      return if @details.fetch("metric") == "missed"

      raise ArgumentError unless minutes == minutes.to_i
      maximum = @issue.kind == "anomaly" ? AnomalyRule::MAX_WINDOW_MINUTES : Threshold::MAX_WINDOW_MINUTES
      raise ArgumentError if minutes > maximum
    end

    def validate_numeric_object!(key, fields)
      value = @details[key]
      return if value.nil?
      raise ArgumentError unless value.is_a?(Hash)
      fields.each { |field| raise ArgumentError if value.key?(field) && !finite_number?(value[field]) }
      if key == "measurement"
        %w[value limit].each { |field| raise ArgumentError if value.key?(field) && value[field].negative? }
        raise ArgumentError if value.key?("limit") && !value["limit"].positive?
      else
        %w[mean stddev].each { |field| raise ArgumentError if value.key?(field) && value[field].negative? }
        raise ArgumentError if value.key?("days") && (!value["days"].is_a?(Integer) || !value["days"].positive?)
        raise ArgumentError if value.key?("deviation") && !value["deviation"].positive?
      end
    end

    def validate_rule!
      rule = @details["rule"]
      if rule.nil?
        raise ArgumentError if @details.fetch("metric") == "missed"
        return
      end
      raise ArgumentError unless rule.is_a?(Hash)
      RULE_STRING_FIELDS.each do |field|
        raise ArgumentError if rule.key?(field) && (!rule[field].is_a?(String) || rule[field].blank?)
      end
      raise ArgumentError if rule.key?("id") && (!rule["id"].is_a?(Integer) || !rule["id"].positive?)
      %w[last_run expected].each { |field| Time.iso8601(rule[field]) if rule.key?(field) }
      return unless @details.fetch("metric") == "missed"

      raise ArgumentError unless rule["type"] == "schedule"
      %w[task_key schedule last_run expected].each { |field| raise ArgumentError unless rule[field].is_a?(String) && rule[field].present? }
    end

    def validate_detector_shape!
      if @issue.kind == "anomaly"
        require_numeric_fields!("measurement", %w[value])
        baseline = require_numeric_fields!("baseline", %w[mean stddev sigmas days deviation])
        raise ArgumentError unless baseline.fetch("sigmas").positive?
        raise ArgumentError unless baseline.fetch("days").between?(
          AnomalyRule::MIN_BASELINE_DAYS, AnomalyRule::MAX_BASELINE_DAYS
        )
        raise ArgumentError if baseline.fetch("deviation") > AnomalyRule::MAX_DEVIATION
        require_detector_rule!("anomaly")
      elsif @details.fetch("metric") != "missed"
        measurement = require_numeric_fields!("measurement", %w[value limit])
        raise ArgumentError if measurement.fetch("limit") > Threshold::MAX_LIMIT
        raise ArgumentError if @details.fetch("metric").end_with?("rate") && measurement.fetch("limit") > 100
        require_detector_rule!("threshold")
      end
    end

    def require_numeric_fields!(key, fields)
      object = @details.fetch(key)
      raise ArgumentError unless object.is_a?(Hash)
      fields.each { |field| raise ArgumentError unless finite_number?(object.fetch(field)) }
      object
    end

    def require_detector_rule!(type)
      rule = @details.fetch("rule")
      raise ArgumentError unless rule.is_a?(Hash) && rule.fetch("type") == type
      raise ArgumentError unless rule.fetch("id").is_a?(Integer) && rule.fetch("id").positive?
      raise ArgumentError unless rule.fetch("target").is_a?(String) && rule.fetch("target").present?
      expected_target_kind = TARGET_KIND_FOR.fetch(@details.fetch("telemetry_type"))
      raise ArgumentError unless rule.fetch("target_kind") == expected_target_kind
    end

    def validate_representatives!
      references = @details.fetch("representative_records", [])
      raise ArgumentError unless references.is_a?(Array) && references.size <= IssueDetectionSnapshot::REPRESENTATIVE_LIMIT

      references.each do |reference|
        raise ArgumentError unless reference.is_a?(Hash)
        raise ArgumentError unless reference["record_type"] == @details.fetch("telemetry_type")
        raise ArgumentError unless reference["record_id"].is_a?(Integer) && reference["record_id"].positive?
        raise ArgumentError unless reference["group_hash"] == @details.fetch("telemetry_group_hash")
        execution_id = reference["execution_id"]
        raise ArgumentError unless execution_id.nil? || (execution_id.is_a?(String) && execution_id.present?)
        raise ArgumentError if reference["record_type"] != "query" && execution_id.blank?
        source = reference["execution_source"]
        if CHILD_TYPES.include?(reference["record_type"])
          raise ArgumentError unless source.is_a?(String) && source.present? && source.in?(EXECUTION_SOURCES)
        else
          raise ArgumentError unless source == reference["record_type"]
        end
      end
    end

    def finite_number?(value)
      value.is_a?(Numeric) && (!value.respond_to?(:finite?) || value.finite?)
    end

    def live_details
      type = @details.fetch("telemetry_type")
      group_hash = @details.fetch("telemetry_group_hash")
      window = @details.fetch("window")
      from = Time.iso8601(window.fetch("from"))
      to = Time.iso8601(window.fetch("to"))
      rollups = Telemetry::Rollup.for_type(type).where(group_hash: group_hash)
      window_summary = Telemetry::Rollup.summarize(rollups.between(from, to))
      now = Time.current
      # Rollup.between includes the whole lower-bound hour, so the denominator
      # for count rates must begin at that same boundary.
      trend_from = (now - TREND_DAYS.days).beginning_of_hour
      trend_rows = rollups.between(trend_from, now).order(:bucket).to_a.group_by { |row| row.bucket.to_date }
      {
        event_count: window_summary[:count],
        trend: trend_rows.map { |day, rows| trend_point(day, rows, trend_from, now) },
        deploy_comparison: deploy_comparison(type, group_hash)
      }
    end

    def trend_point(day, rows, trend_from, now)
      summary = Telemetry::Rollup.summarize(rows)
      day_start = day.in_time_zone.beginning_of_day
      minutes = ([ day_start + 1.day, now ].min - [ day_start, trend_from ].max) / 60.0
      { day: day.iso8601, value: metric_value(@details.fetch("metric"), summary, minutes: minutes), count: summary[:count] }
    end

    def metric_value(metric, summary, minutes: nil)
      case metric
      when "p95" then milliseconds(summary[:p95])
      when "max" then milliseconds(summary[:max])
      when "avg" then milliseconds(summary[:avg])
      when "error_rate", "failure_rate"
        summary[:count].zero? ? nil : (summary[:errors] * 100.0 / summary[:count]).round(2)
      when "count" then minutes&.positive? ? (summary[:count] / minutes).round(2) : nil
      end
    end

    def deploy_comparison(type, group_hash)
      scope = record_scope(type, group_hash).where(occurred_at: TREND_DAYS.days.ago..).where.not(deploy: nil)
      scope.group(:deploy).pluck(:deploy, Arel.sql("COUNT(*)"), Arel.sql("AVG(duration)"), Arel.sql("MAX(duration)"))
        .map { |deploy, count, avg, max| { deploy: deploy, events: count, avg_ms: milliseconds(avg), max_ms: milliseconds(max) } }
        .sort_by { |row| -row[:events] }.first(DEPLOY_LIMIT)
    end

    def record_scope(type, group_hash)
      if type.in?(EXECUTION_TYPES)
        Telemetry::Execution.of_kind(type).where(group_hash: group_hash)
      elsif type == "query"
        Telemetry::Query.where(group_hash: group_hash).with_sql
      elsif type == "outgoing_request"
        Telemetry::OutgoingRequest.where(group_hash: group_hash)
      else
        raise ArgumentError, "unsupported detection telemetry type: #{type}"
      end
    end

    def representatives
      references = Array(@details["representative_records"]).select { |record| record.is_a?(Hash) }
      return [] if references.empty?

      type = @details.fetch("telemetry_type")
      group_hash = @details.fetch("telemetry_group_hash")
      records = @issue.environment.with_telemetry do
        record_scope(type, group_hash).where(id: references.filter_map { |record| record["record_id"] }).index_by(&:id)
      end
      references.filter_map do |reference|
        record = records[reference["record_id"]]
        record_json(record, type)&.merge(drilldown: drilldown(reference))
      end
    end

    def representative_references
      Array(@details["representative_records"]).filter_map do |reference|
        next unless reference.is_a?(Hash)
        reference.slice("record_type", "record_id", "group_hash", "execution_id", "execution_source").deep_symbolize_keys
          .merge(drilldown: drilldown(reference))
      end
    end

    def record_json(record, type)
      return unless record

      common = {
        record_type: type, record_id: record.id, group_hash: record.group_hash,
        execution_id: record.execution_id, execution_source: record.execution_source,
        execution_preview: record.execution_preview, occurred_at: record.occurred_at,
        duration_ms: milliseconds(record.duration), deploy: record.deploy,
        user_ref: record.user_ref, tenant: record.app_tenant
      }
      case record
      when Telemetry::Execution
        common.merge(name: record.name, status: record.status, outcome: record.outcome)
      when Telemetry::Query
        common.merge(name: record.sql.to_s.first(300), source: record.source,
          connection: record.connection, role: record.role)
      when Telemetry::OutgoingRequest
        common.merge(name: "#{record.method} #{record.host}", status: record.status_code,
          source: record.source)
      end
    end

    # Identifiers only: app/frontend/lib/execution-path.ts turns these into
    # links, and it already accepts both the "job" child wire name and the
    # "job_attempt" parent kind.
    def drilldown(record)
      if record["record_type"] == "query"
        { kind: "query", group_hash: record["group_hash"] }
      elsif record["execution_id"].present?
        { kind: record["execution_source"].presence || record["record_type"], execution_id: record["execution_id"] }
      end
    end

    def milliseconds(value)
      value.nil? ? nil : (value.to_f / 1000.0).round(3)
    end
  end
end
