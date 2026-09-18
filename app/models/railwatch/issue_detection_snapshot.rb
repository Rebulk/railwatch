# frozen_string_literal: true

module Railwatch
  # Durable, typed context for synthetic performance/anomaly issues. Detector
  # group hashes identify the rule, not the telemetry rows behind the breach;
  # this snapshot preserves that original identity and a bounded set of
  # drill-down identifiers even after raw telemetry is pruned. Record payloads
  # remain subject to the telemetry retention policy and are never copied into
  # the primary database.
  class IssueDetectionSnapshot
    REPRESENTATIVE_LIMIT = 10
    EXECUTION_TYPES = %w[request job_attempt scheduled_task command].freeze
    UNITS = {
      "p95" => "milliseconds", "max" => "milliseconds", "avg" => "milliseconds",
      "error_rate" => "percent", "failure_rate" => "percent", "count" => "events_per_minute",
      "missed" => "schedule"
    }.freeze

    def self.capture(environment:, kind:, telemetry_type:, telemetry_group_hash:, target:, metric:, from:, to:,
      value: nil, limit: nil, baseline: nil, rule: {}, representative_from: nil)
      new(environment, telemetry_type, telemetry_group_hash).capture(
        kind: kind, target: target, metric: metric, from: from, to: to,
        value: value, limit: limit, baseline: baseline, rule: rule, representative_from: representative_from
      )
    end

    def initialize(environment, telemetry_type, telemetry_group_hash)
      @environment = environment
      @telemetry_type = telemetry_type
      @telemetry_group_hash = telemetry_group_hash
    end

    def capture(kind:, target:, metric:, from:, to:, value:, limit:, baseline:, rule:, representative_from:)
      representatives = @environment.with_telemetry do
        representative_scope(representative_from || from, to).order(duration: :desc).limit(REPRESENTATIVE_LIMIT)
          .map { |record| record_json(record) }
      end
      {
        schema_version: 1, kind: kind, telemetry_type: @telemetry_type,
        telemetry_group_hash: @telemetry_group_hash, target: target, metric: metric,
        unit: UNITS.fetch(metric, "value"),
        window: { from: from.iso8601(6), to: to.iso8601(6), minutes: ((to - from) / 60.0).round(2) },
        measurement: { value: value, limit: limit }.compact,
        baseline: baseline&.compact,
        rule: rule.compact,
        representative_records: representatives
      }.compact
    end

    private

    def representative_scope(from, to)
      model = record_model
      # SQLite compares its stored six-digit timestamp strings lexically. A
      # frozen whole-second upper bound serializes without the fraction and
      # would otherwise exclude a record at that exact instant.
      scope = model.where(group_hash: @telemetry_group_hash, occurred_at: from...(to + 1.second))
      EXECUTION_TYPES.include?(@telemetry_type) ? scope.of_kind(@telemetry_type) : scope
    end

    def record_model
      return Telemetry::Execution if EXECUTION_TYPES.include?(@telemetry_type)
      return Telemetry::Query if @telemetry_type == "query"
      return Telemetry::OutgoingRequest if @telemetry_type == "outgoing_request"

      raise ArgumentError, "unsupported detection telemetry type: #{@telemetry_type}"
    end

    def record_json(record)
      {
        record_type: @telemetry_type, record_id: record.id, group_hash: record.group_hash,
        execution_id: record.execution_id,
        execution_source: record.is_a?(Telemetry::Execution) ? record.kind : record.execution_source
      }
    end
  end
end
