# frozen_string_literal: true

module Railwatch
    class CacheEventsController < DashboardController
    def index
      from, to = window_range
      fields = FilterQuery.parse(params[:q]).fetch(:fields)
      keys = telemetry do
        scope = Telemetry::Rollup.for_type("cache_event").between(from, to)
        if fields["store"].present?
          # Rollup rows have no store column; find the matching group_hashes
          # from the raw cache_events for this window and filter by those.
          hashes = Telemetry::CacheEvent.between(from, to).where(store: fields["store"]).distinct.pluck(:group_hash)
          scope = scope.where(group_hash: hashes)
        end
        rows = scope.to_a
        rows.group_by(&:group_hash).map do |group_hash, group_rows|
          count = group_rows.sum(&:count)
          hits = group_rows.sum { |r| r.extra["hits"].to_i }
          misses = group_rows.sum { |r| r.extra["misses"].to_i }
          duration_sum = group_rows.sum(&:duration_sum)
          { group_hash: group_hash, key: group_rows.max_by(&:bucket).name, count: count, hits: hits, misses: misses,
           hit_rate: (hits + misses).zero? ? nil : (hits * 100.0 / (hits + misses)).round(1),
           avg: count.zero? ? 0 : (duration_sum / count / 1000.0).round(3), sparkline: Telemetry::Aggregations.sparkline(group_rows, from, to) }
        end.sort_by { |r| -r[:count] }.first(200)
      end
      render inertia: { keys: keys, series: series("cache_event"), q: params[:q].to_s }
    end
    end
end
