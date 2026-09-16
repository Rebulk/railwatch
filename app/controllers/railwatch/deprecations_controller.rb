# frozen_string_literal: true

module Railwatch
    class DeprecationsController < DashboardController
    def index
      from, to = window_range
      parsed = FilterQuery.parse(params[:q])
      fields = parsed[:fields]
      data = telemetry do
        scope = Telemetry::Deprecation.between(from, to)
        scope = scope.where(gem_name: fields["gem"]) if fields["gem"].present?
        scope = scope.where("message LIKE ?", "%#{Telemetry::Deprecation.sanitize_sql_like(parsed[:text])}%") if parsed[:text].present?
        rows = scope.to_a
        hashes = rows.map(&:group_hash).uniq
        first_ever = Telemetry::Deprecation.where(group_hash: hashes).group(:group_hash).minimum(:occurred_at)
        groups = rows.group_by(&:group_hash)
                     .map { |group_hash, group_rows| deprecation_row(group_hash, group_rows, first_ever[group_hash], from, to) }
                     .sort_by { |r| -r[:count] }
        { groups: groups.first(200), distinct: groups.size, total_occurrences: groups.sum { |g| g[:count] },
         new_this_window: groups.count { |g| g[:first_seen_at] && g[:first_seen_at] >= from } }
      end
      render inertia: { deprecations: data[:groups], distinct: data[:distinct], total_occurrences: data[:total_occurrences],
                        new_this_window: data[:new_this_window], q: params[:q].to_s }
    end

    private

    def deprecation_row(group_hash, group_rows, first_seen_at, from, to)
      sorted = group_rows.sort_by(&:occurred_at)
      { group_hash: group_hash, message: sorted.last.message, gem_name: sorted.last.gem_name, horizon: sorted.last.horizon,
        source: sorted.last.source, count: group_rows.size, first_seen_at: first_seen_at, last_seen_at: sorted.last.occurred_at,
        sparkline: hourly_sparkline(group_rows, from, to), occurrences: sorted.reverse.first(20).map { |r| occurrence_row(r) } }
    end

    def occurrence_row(r)
      { id: r.id, occurred_at: r.occurred_at, execution_id: r.execution_id, execution_source: r.execution_source,
        execution_preview: r.execution_preview }
    end

    # Hourly counts for raw (non-rollup) rows, zero-filled and coarsened to at
    # most 30 points for wide windows -- deprecations have no duration column
    # so they never land in Telemetry::Rollup and can't use
    # EnvironmentScoped#sparkline, which keys off a rollup row's bucket/count.
    def hourly_sparkline(rows, from, to)
      hours = [ ((to - from) / 1.hour).ceil, 1 ].max
      coarsen = (hours / 30.0).ceil
      base = from.beginning_of_hour
      buckets = Hash.new(0)
      rows.each { |r| buckets[((r.occurred_at - base) / 1.hour).to_i / coarsen] += 1 }
      bucket_count = (hours.to_f / coarsen).ceil
      (0...bucket_count).map { |i| buckets[i] }
    end
    end
end
