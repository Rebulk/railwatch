# frozen_string_literal: true

module Railwatch
  module Telemetry
    # Pure per-environment rollup aggregation: time-bucketed series, grouped
    # tables, and window-over-window summaries. Takes explicit from/to rather
    # than reading a controller's window params, so it's the same math for the
    # web dashboard (EnvironmentScoped) and the public API (Api::V1).
    class Aggregations
      GROUPED_SORT_FIELDS = %i[count p50 p95 p99 errors avg max].freeze

      # Time-bucketed series from rollups for charts: [{t, count, errors, p50, p95, p99}]
      def self.series(environment, record_type, from:, to:, group_hash: nil, name: nil)
        environment.with_telemetry do
          scope = Telemetry::Rollup.for_type(record_type).between(from, to)
          scope = scope.where(group_hash: group_hash) if group_hash
          scope = scope.where(name: name) if name
          scope.group(:bucket).order(:bucket)
               .pluck(:bucket, Arel.sql("SUM(count)"), Arel.sql("SUM(error_count)"), Arel.sql("SUM(client_error_count)"), Arel.sql("SUM(duration_sum)"), Arel.sql("MAX(p50)"), Arel.sql("MAX(p95)"), Arel.sql("MAX(p99)"))
               .map { |b, c, e, ce, ds, p50, p95, p99| { t: b, count: c, errors: e, client_errors: ce, avg: c.zero? ? 0 : ds / c / 1000.0, p50: p50 / 1000.0, p95: p95 / 1000.0, p99: p99 / 1000.0 } }
        end
      end

      # Per-group table rows for a record type in the window: count/error totals,
      # merged percentiles (via Telemetry::Rollup.summarize), and a sparkline.
      def self.grouped(environment, record_type, from:, to:, limit: 100, order: nil, dir: nil)
        order = GROUPED_SORT_FIELDS.include?(order.to_s.to_sym) ? order.to_s.to_sym : :count
        sign = dir.to_s == "asc" ? 1 : -1
        # Same minute cache as summary_with_delta, for the same reason: the
        # 200 busiest query groups on the rebulk environment span 1,500 rollup
        # rows and 55,000 centroids, and merging those digests is 480ms that
        # only changes when RollupJob writes.
        key = [ "aggregations", "grouped", environment.id, record_type, limit, order, sign, from.to_i / 60, to.to_i / 60 ]
        cached(key) { grouped_uncached(environment, record_type, from: from, to: to, limit: limit, order: order, sign: sign) }
      end

      def self.grouped_uncached(environment, record_type, from:, to:, limit:, order:, sign:)
        environment.with_telemetry do
          rows = Telemetry::Rollup.for_type(record_type).between(from, to).to_a
          groups = rows.group_by(&:group_hash)
          # Merging t-digests is the expensive part (the queries page has 2,000
          # groups over 8,500 rows: 500ms of digest merges for a table that
          # shows 200). Sort on what the columns already hold -- counts, sums
          # and maxima need no digest -- and only merge percentiles for the
          # groups that make the cut. A percentile sort falls back to the full
          # merge, since the ranking itself needs the digest.
          cheap = %i[count errors avg max].include?(order)
          ranked = groups.map { |group_hash, group_rows| [ group_hash, group_rows, cheap ? cheap_summary(group_rows) : Telemetry::Rollup.summarize(group_rows) ] }
          ranked.sort_by! { |_, _, summary| summary[order] * sign }
          ranked.first(limit).map do |group_hash, group_rows, summary|
            summary = Telemetry::Rollup.summarize(group_rows) if cheap
            {
              group_hash: group_hash, name: group_rows.max_by(&:bucket).name,
              count: summary[:count], errors: summary[:errors], client_errors: summary[:client_errors],
              avg: (summary[:avg] / 1000.0).round(2), p50: (summary[:p50] / 1000.0).round(2),
              p95: (summary[:p95] / 1000.0).round(2), p99: (summary[:p99] / 1000.0).round(2),
              max: (summary[:max] / 1000.0).round(2), sparkline: sparkline(group_rows, from, to)
            }
          end
        end
      end

      # The minute cache exists because the platform's rollups only change
      # when RollupJob writes. Embedded, every batch updates them and one
      # person is looking, so the cache would only make the page a minute
      # stale for nothing.
      def self.cached(key, &block)
        return yield if Railwatch.config.local?

        Rails.cache.fetch(key, expires_in: 1.minute, &block)
      end

      # The digest-free half of Rollup.summarize: everything the sort keys
      # that are not percentiles need.
      def self.cheap_summary(rows)
        count = rows.sum(&:count)
        { count: count, errors: rows.sum(&:error_count),
         avg: count.zero? ? 0 : (rows.sum(&:duration_sum) / count), max: rows.map(&:duration_max).max }
      end

      # { current: Summary, previous: Summary } so pages/endpoints can show deltas.
      # Cached for a minute per window. The two totals merge every rollup
      # digest in both windows (18,000 rows, 355ms on the rebulk environment's
      # queries page) to produce four numbers that only move when RollupJob
      # writes, which is at most once a minute per bucket; without this the
      # merge ran again on every page load.
      def self.summary_with_delta(environment, record_type, from:, to:, previous_from:, previous_to:, group_hash: nil)
        key = [ "aggregations", "summary_with_delta", environment.id, record_type, group_hash,
               from.to_i / 60, to.to_i / 60, previous_from.to_i / 60, previous_to.to_i / 60 ]
        cached(key) do
          environment.with_telemetry do
            current = Telemetry::Rollup.for_type(record_type).between(from, to)
            previous = Telemetry::Rollup.for_type(record_type).between(previous_from, previous_to)
            if group_hash
              current = current.where(group_hash: group_hash)
              previous = previous.where(group_hash: group_hash)
            end
            { current: Telemetry::Rollup.summarize(current), previous: Telemetry::Rollup.summarize(previous) }
          end
        end
      end

      # Hourly counts for a set of same-window rollup rows, zero-filled, coarsened
      # to at most 30 points for wide windows (7d/30d).
      def self.sparkline(rows, from, to)
        hours = [ ((to - from) / 1.hour).ceil, 1 ].max
        coarsen = (hours / 30.0).ceil
        base = from.beginning_of_hour
        buckets = Hash.new(0)
        rows.each { |r| buckets[((r.bucket - base) / 1.hour).to_i / coarsen] += r.count }
        bucket_count = (hours.to_f / coarsen).ceil
        (0...bucket_count).map { |i| buckets[i] }
      end
    end
  end
end
