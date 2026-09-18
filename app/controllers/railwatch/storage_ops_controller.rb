# frozen_string_literal: true

module Railwatch
    class StorageOpsController < DashboardController
    def index
      from, to = window_range
      ops = telemetry do
        Telemetry::StorageOp.between(from, to).group(:service, :op).pluck(:service, :op, Arel.sql("COUNT(*)"), Arel.sql("AVG(duration)"), Arel.sql("MAX(duration)"))
          .map { |s, o, c, avg, mx| { service: s, op: o, count: c, avg: (avg.to_f / 1000.0).round(1), max: (mx.to_f / 1000.0).round(1) } }
      end
      recent = telemetry { Telemetry::StorageOp.between(from, to).recent.limit(100).map { |r| { id: r.id, service: r.service, op: r.op, key: r.key, duration: r.duration_ms.round(1), occurred_at: r.occurred_at, execution_id: r.execution_id, execution_preview: r.execution_preview } } }
      render inertia: { ops: ops, recent: recent }
    end
    end
end
