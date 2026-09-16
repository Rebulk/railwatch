# frozen_string_literal: true

module Railwatch
    class BroadcastsController < DashboardController
    def index
      from, to = window_range
      streams = telemetry do
        Telemetry::Broadcast.between(from, to).group(:group_hash, :kind).pluck(:group_hash, :kind, Arel.sql("MAX(COALESCE(stream, channel))"), Arel.sql("COUNT(*)"), Arel.sql("SUM(bytes)"), Arel.sql("AVG(duration)"))
          .map { |g, k, name, c, b, d| { group_hash: g, kind: k, name: name, count: c, bytes: b.to_i, avg: (d.to_f / 1000.0).round(3) } }.sort_by { |r| -r[:count] }.first(200)
      end
      recent = telemetry { Telemetry::Broadcast.between(from, to).recent.limit(100).map { |b| { id: b.id, kind: b.kind, stream: b.stream, channel: b.channel, action: b.action, bytes: b.bytes, failed: b.failed, duration: b.duration_ms.round(3), occurred_at: b.occurred_at, execution_id: b.execution_id, execution_preview: b.execution_preview } } }
      render inertia: { streams: streams, recent: recent }
    end
    end
end
