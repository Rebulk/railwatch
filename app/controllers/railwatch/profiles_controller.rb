# frozen_string_literal: true

module Railwatch
    class ProfilesController < DashboardController
    # Profiles are never rolled up (they are opt-in and sampled, so a rollup
    # row would be noise), which means every number on these pages comes from
    # the raw table. This caps how many rows the grouping pass reads; the
    # StatStrip totals still come from SQL aggregates over the whole window.
    SCAN_LIMIT = 5_000

    def index
      from, to = window_range
      rows, count, avg_samples, profiled, executions = telemetry do
        scope = Telemetry::Profile.between(from, to)
        [ scope.recent.limit(SCAN_LIMIT).select(:id, :group_hash, :execution_preview, :duration, :samples, :occurred_at).to_a,
          scope.count, scope.average(:samples), scope.distinct.count(:execution_id), Telemetry::Execution.between(from, to).count ]
      end
      render inertia: { profiles: groups(rows),
                        summary: { profiles: count, executions: executions, profiled: profiled, avg_samples: avg_samples.to_f.round(0) } }
    end

    def show
      profile = telemetry { Telemetry::Profile.find(params[:id]) }
      collapsed, truncated = profile.collapsed_capped
      render inertia: { profile: profile_row(profile), collapsed: collapsed, truncated: truncated }
    rescue Telemetry::BoundedGzip::Error
      head :unprocessable_content
    end

    private

    # Rows arrive newest-first, so the head of each group is the profile the
    # page links to.
    def groups(rows)
      rows.group_by(&:group_hash).map { |group_hash, group|
        newest = group.first
        { group_hash: group_hash, name: newest.execution_preview, profile_id: newest.id, count: group.size,
          avg_duration: (group.sum { |row| row.duration.to_i } / group.size.to_f / 1000.0).round(2),
          max_samples: group.filter_map(&:samples).max, last_seen_at: newest.occurred_at }
      }.sort_by { |g| -g[:count] }.first(100)
    end

    def profile_row(row)
      { id: row.id, profiler: row.profiler, mode: row.mode, interval: row.interval, duration: row.duration_ms.round(2),
        samples: row.samples, stacks_bytes: row.stacks_bytes, group_hash: row.group_hash, execution_id: row.execution_id,
        execution_preview: row.execution_preview, execution_source: row.execution_source, occurred_at: row.occurred_at,
        deploy: row.deploy, server: row.server }
    end
    end
end
