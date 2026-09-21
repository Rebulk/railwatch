# frozen_string_literal: true

module Railwatch
  module Telemetry
    # Pure per-environment rollup aggregation: time-bucketed series, grouped
    # tables, and window-over-window summaries. Takes explicit from/to rather
    # than reading a controller's window params, so it's the same math for the
    # web dashboard (EnvironmentScoped) and the public API (Api::V1).
    class Aggregations
      GROUPED_SORT_FIELDS = %i[count p50 p95 p99 errors avg max].freeze

      # Bucket widths a chart can be drawn at. Anything under an hour is read
      # from the raw tables (rollups are hourly); an hour and up groups rollups.
      STEPS = { "1m" => 1.minute, "5m" => 5.minutes, "15m" => 15.minutes, "1h" => 1.hour, "6h" => 6.hours, "1d" => 1.day }.freeze
      # A step is offered for a window when it draws at least two points and at
      # most this many: more bars than pixels is mush, and a sub-hour step over
      # a long window is also a long raw scan.
      MAX_POINTS = 400

      # The bucket a window is drawn at unless the page asks for another one.
      # Sub-hour steps scan raw rows, so they are the default only where that
      # scan is a few thousand rows; a day and beyond stays on rollups.
      def self.default_step(from, to)
        span = to - from
        if span <= 2.hours then "1m"
        elsif span <= 12.hours then "5m"
        elsif span <= 7.days then "1h"
        else "6h"
        end
      end

      # STEPS keys that make sense for the window, finest first.
      def self.steps_for(from, to)
        span = to - from
        STEPS.select { |_key, step| (span / step).between?(2, MAX_POINTS) }.keys
      end

      # Time-bucketed series for charts, one point per `step` from `from` to `to`
      # with empty buckets filled in: [{t, count, errors, client_errors, avg,
      # p50, p95, p99}]. Durations in milliseconds; an empty bucket carries nil
      # for them so a latency line breaks instead of dropping to zero.
      def self.series(environment, record_type, from:, to:, group_hash: nil, step: nil, tenant: nil)
        environment.with_telemetry { points(record_type, from: from, to: to, group_hash: group_hash, step: step, tenant: tenant) }
      end

      # `series` for a caller already inside environment.with_telemetry. A
      # tenant narrows to one app_tenant, which rollups do not carry, so a
      # tenant series reads raw rows at every step.
      def self.points(record_type, from:, to:, group_hash: nil, step: nil, tenant: nil)
        step = STEPS.fetch(step || default_step(from, to))
        raw = step < 1.hour || tenant
        points = raw ? raw_series(record_type, from, to, group_hash, step, tenant) : rollup_series(record_type, from, to, group_hash, step)
        fill(points, from, to, step)
      end

      # Sums hourly rollups into `step`-wide buckets. Percentiles are the
      # worst hour's, the same reading series always gave across groups.
      def self.rollup_series(record_type, from, to, group_hash, step)
        bucket = bucket_sql("bucket", step)
        scope = Telemetry::Rollup.for_type(record_type).between(from, to)
        scope = scope.where(group_hash: group_hash) if group_hash
        scope.group(bucket).order(bucket)
             .pluck(bucket, Arel.sql("SUM(count)"), Arel.sql("SUM(error_count)"), Arel.sql("SUM(client_error_count)"), Arel.sql("SUM(duration_sum)"), Arel.sql("MAX(p50)"), Arel.sql("MAX(p95)"), Arel.sql("MAX(p99)"))
             .map { |b, c, e, ce, ds, p50, p95, p99| point(b, c, e, ce, ds, p50, p95, p99) }
      end

      # What a raw row of each record type is, and when it counts as an error
      # (or a client error), mirroring RollupJob#error?. Both readings of the
      # same rows must agree, which spec/models/telemetry/aggregations_spec.rb
      # checks for every type.
      RAW = {
        "request" => [ -> { Telemetry::Execution.requests }, "status >= 500", "status BETWEEN 400 AND 499" ],
        "job_attempt" => [ -> { Telemetry::Execution.jobs }, "outcome = 'failed'" ],
        "scheduled_task" => [ -> { Telemetry::Execution.scheduled }, "outcome = 'failed'" ],
        "command" => [ -> { Telemetry::Execution.commands }, "status != 0" ],
        "channel_action" => [ -> { Telemetry::Execution.channels }, "outcome = 'failed'" ],
        "query" => [ -> { Telemetry::Query.all } ],
        "outgoing_request" => [ -> { Telemetry::OutgoingRequest.all }, "status_code >= 500 OR status_code IS NULL OR status_code = 0" ],
        "cache_event" => [ -> { Telemetry::CacheEvent.all } ],
        "mail" => [ -> { Telemetry::Mail.all }, "failed" ],
        "visit" => [ -> { Telemetry::Visit.all }, "status = 'error'" ],
        "span" => [ -> { Telemetry::Span.all }, "status = 'failed'" ],
        "notification" => [ -> { Telemetry::Notification.all }, "failed" ],
        "view_render" => [ -> { Telemetry::ViewRender.all } ],
        "transaction" => [ -> { Telemetry::Transaction.all }, "outcome = 'rollback'" ],
        "llm_call" => [ -> { Telemetry::LlmCall.models }, "status = 'failed'" ],
        "llm_tool" => [ -> { Telemetry::LlmCall.tools }, "status = 'failed'" ]
      }.freeze

      # Sub-hour buckets straight from the raw rows, in one statement:
      # counts and sums per bucket, and exact nearest-rank percentiles from a
      # ROW_NUMBER over each bucket's durations. Rollups are hourly, so this
      # is the only reading finer than an hour; it is also the freshest one,
      # since the current hour's rollup is up to a minute behind.
      def self.raw_series(record_type, from, to, group_hash, step, tenant = nil)
        scope, error_sql, client_error_sql = RAW.fetch(record_type)
        rows = scope.call.where(occurred_at: from..to)
        rows = rows.where(group_hash: group_hash) if group_hash
        rows = rows.where(app_tenant: tenant) if tenant
        model = rows.model
        inner = rows.select(bucket_sql("occurred_at", step).to_s + " AS b", "duration", flag_sql(error_sql) + " AS err", flag_sql(client_error_sql) + " AS cerr")
        ranked = model.unscoped.from(inner, "r").select("b", "duration", "err", "cerr",
          "ROW_NUMBER() OVER (PARTITION BY b ORDER BY duration) AS rn", "COUNT(*) OVER (PARTITION BY b) AS n")
        model.unscoped.from(ranked, "w").group("b").order("b")
          .pluck(Arel.sql("b"), Arel.sql("COUNT(*)"), Arel.sql("SUM(err)"), Arel.sql("SUM(cerr)"), Arel.sql("SUM(duration)"),
                 rank_sql(50), rank_sql(95), rank_sql(99))
          .map { |b, c, e, ce, ds, p50, p95, p99| point(b, c, e, ce, ds, p50, p95, p99) }
      end

      # The timestamp columns a series buckets on: raw rows by occurred_at,
      # rollups and release health by their hourly bucket.
      BUCKET_COLUMNS = %w[occurred_at bucket].freeze

      # Epoch seconds of the start of the `step`-wide bucket holding `column`.
      # `column` must be one of BUCKET_COLUMNS and `step` is a Duration, so the
      # fragment can only ever hold a listed column name and an integer literal.
      def self.bucket_sql(column, step)
        raise ArgumentError, "unknown bucket column #{column.inspect}" unless BUCKET_COLUMNS.include?(column)
        seconds = Integer(step.to_i)
        Arel.sql("(strftime('%s', #{column}) / #{seconds}) * #{seconds}")
      end

      # One point per bucket from `from` to `to`, keeping the computed ones and
      # zero-filling the rest, so a quiet minute is a gap of the right width.
      # A series with its own point shape passes a block building its empty one.
      def self.fill(points, from, to, step)
        by_bucket = points.index_by { |p| p[:t] }
        first = Time.at((from.to_i / step.to_i) * step.to_i).utc
        last = Time.at((to.to_i / step.to_i) * step.to_i).utc
        (first.to_i..last.to_i).step(step.to_i).map do |t|
          at = Time.at(t).utc
          by_bucket[at] || (block_given? ? yield(at) : empty_point(at))
        end
      end

      def self.point(bucket, count, errors, client_errors, duration_sum, p50, p95, p99)
        { t: Time.at(bucket).utc, count: count, errors: errors, client_errors: client_errors,
         avg: count.zero? ? 0 : duration_sum / count / 1000.0, p50: p50 / 1000.0, p95: p95 / 1000.0, p99: p99 / 1000.0 }
      end

      def self.empty_point(t)
        { t: t, count: 0, errors: 0, client_errors: 0, avg: nil, p50: nil, p95: nil, p99: nil }
      end

      def self.flag_sql(predicate)
        predicate ? "CASE WHEN #{predicate} THEN 1 ELSE 0 END" : "0"
      end

      # The nearest-rank percentile: the duration whose rank is ceil(n * p/100).
      RANK_SQL = { 50 => Arel.sql("MAX(CASE WHEN rn = (n * 50 + 99) / 100 THEN duration END)"),
                  95 => Arel.sql("MAX(CASE WHEN rn = (n * 95 + 99) / 100 THEN duration END)"),
                  99 => Arel.sql("MAX(CASE WHEN rn = (n * 99 + 99) / 100 THEN duration END)") }.freeze

      def self.rank_sql(percent)
        RANK_SQL.fetch(percent)
      end

      private_class_method :rollup_series, :raw_series, :point, :empty_point, :flag_sql, :rank_sql

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

      # The minute cache exists because the platform's rollups only change
      # when RollupJob writes. Embedded, every batch updates them and one
      # person is looking, so the cache would only make the page a minute
      # stale for nothing.
      def self.cached(key, &block)
        return yield if Railwatch.config.local?
        Rails.cache.fetch(key, expires_in: 1.minute, &block)
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
