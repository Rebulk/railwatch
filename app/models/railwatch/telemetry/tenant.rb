# frozen_string_literal: true

module Railwatch
  module Telemetry
    # A tenant of the monitored application, as seen in its telemetry. Not an
    # Active Record table: `app_tenant` is a column on every telemetry row (the
    # gem fills it from Railwatch::Context.current_tenant, which multi-tenant
    # Rails apps get from ActiveRecord::Tenanted / TenantRecord.current_tenant),
    # so a "tenant" only exists as a GROUP BY over the raw tables.
    #
    # Telemetry::Rollup -- what every other page's numbers come from -- is keyed
    # by record type and group_hash only and has no tenant dimension, so all of
    # this is computed from raw rows in the window. Every method must run inside
    # environment.with_telemetry { }.
    class Tenant
      MAX_TENANTS = 200
      # A p95 costs one ordered query per tenant (SQLite has no percentile
      # aggregate), so only the busiest tenants get one; the rest report 0.
      P95_TENANTS = 50
      SPARKLINE_BUCKETS = 12
      SERIES_BUCKETS = 48
      SORTS = { "requests" => :requests, "errors" => :errors, "p95" => :p95, "users" => :users }.freeze

      ERRORS_SQL = Arel.sql("SUM(CASE WHEN status >= 500 THEN 1 ELSE 0 END)")
      CLIENT_ERRORS_SQL = Arel.sql("SUM(CASE WHEN status BETWEEN 400 AND 499 THEN 1 ELSE 0 END)")
      FAILED_SQL = Arel.sql("SUM(CASE WHEN outcome = 'failed' THEN 1 ELSE 0 END)")
      COUNT_SQL = Arel.sql("COUNT(*)")
      USERS_SQL = Arel.sql("COUNT(DISTINCT user_ref)")

      # One aggregate row per tenant seen in the window, filtered by `q`
      # (a substring of the tenant name), sorted, and capped at MAX_TENANTS.
      def self.index(from, to, q: nil, sort: nil, dir: nil)
        rows = Hash.new { |h, tenant| h[tenant] = blank_row(tenant) }
        absorb_requests(rows, from, to, q)
        absorb_jobs(rows, from, to, q)
        absorb_counts(rows, filtered(Telemetry::Exception.between(from, to), q), :exceptions)
        absorb_counts(rows, filtered(Telemetry::Log.between(from, to), q), :logs)
        absorb_last_seen(rows, from, to, q)
        absorb_sparklines(rows, from, to, q)
        absorb_p95s(rows.values.max_by(P95_TENANTS) { |r| r[:requests] }, from, to)
        sorted(rows.values, sort, dir)
      end

      # Headline numbers for the index page, computed from the rows it shows
      # (so the top-tenant share is a share of the listed tenants' requests)
      # plus the share of requests in the window that carry no tenant at all.
      def self.overview(rows, from, to)
        requests = Telemetry::Execution.requests.between(from, to)
        total = requests.count
        untagged = requests.where(app_tenant: nil).count
        tagged = rows.sum { |r| r[:requests] }
        top = rows.max_by { |r| r[:requests] }
        {
          tenants: rows.size, top_tenant: top && top[:tenant],
          top_share: tagged.zero? ? 0.0 : (top[:requests] * 100.0 / tagged).round(1),
          with_errors: rows.count { |r| r[:errors].positive? },
          untagged_share: total.zero? ? 0.0 : (untagged * 100.0 / total).round(1)
        }
      end

      # Window totals for one tenant. Durations in milliseconds, like the rest
      # of the tenant props.
      def self.summary(tenant, from, to)
        requests = Telemetry::Execution.requests.between(from, to).where(app_tenant: tenant)
        count, errors, users = requests.pick(COUNT_SQL, ERRORS_SQL, USERS_SQL)
        jobs, failed_jobs = Telemetry::Execution.jobs.between(from, to).where(app_tenant: tenant).pick(COUNT_SQL, FAILED_SQL)
        {
          requests: count, errors: errors.to_i, p95: p95_ms(requests, count), jobs: jobs, failed_jobs: failed_jobs.to_i,
          exceptions: Telemetry::Exception.between(from, to).where(app_tenant: tenant).count,
          users: users, logs: Telemetry::Log.between(from, to).where(app_tenant: tenant).count
        }
      end

      # Request volume and duration bucketed over the window, SeriesPoint-shaped
      # so the same charts render it. Percentiles are approximations: these
      # buckets come from raw rows, without the per-bucket t-digest
      # Telemetry::Rollup keeps, so p50 is the bucket's average and p95/p99 its
      # max.
      def self.series(tenant, from, to)
        width = bucket_width(from, to, SERIES_BUCKETS)
        bucket = bucket_sql(from, width)
        Telemetry::Execution.requests.between(from, to).where(app_tenant: tenant).group(bucket)
          .pluck(bucket, COUNT_SQL, ERRORS_SQL, CLIENT_ERRORS_SQL, Arel.sql("SUM(duration)"), Arel.sql("MAX(duration)"))
          .map { |index, count, errors, client_errors, sum, max|
            avg = ms(sum / count)
            { t: bucket_at(from, width, index, SERIES_BUCKETS).iso8601, count: count, errors: errors, client_errors: client_errors,
              avg: avg, p50: avg, p95: ms(max), p99: ms(max) }
          }.sort_by { |point| point[:t] }
      end

      def self.routes(tenant, from, to, limit: 20)
        grouped_executions(Telemetry::Execution.requests, tenant, from, to, ERRORS_SQL, :errors, limit)
      end

      def self.job_classes(tenant, from, to, limit: 10)
        grouped_executions(Telemetry::Execution.jobs, tenant, from, to, FAILED_SQL, :failed, limit)
      end

      def self.exceptions(tenant, from, to, limit: 20)
        Telemetry::Exception.between(from, to).where(app_tenant: tenant).recent.limit(limit).map do |e|
          { id: e.id, class_name: e.class_name, message: e.message.first(500), occurred_at: e.occurred_at,
            execution_id: e.execution_id, group_hash: e.group_hash }
        end
      end

      def self.people(tenant, limit: 20)
        Telemetry::Person.where(app_tenant: tenant).recent.limit(limit).map do |person|
          { ref: person.ref, name: person.display_name, email: person.email, last_seen_at: person.last_seen_at }
        end
      end

      # Same field shape as RequestsController#execution_row, for the tenant
      # page's "Recent requests" table.
      def self.recent_requests(tenant, from, to, limit: 50)
        Telemetry::Execution.requests.between(from, to).where(app_tenant: tenant).recent.limit(limit).map do |r|
          { execution_id: r.execution_id, name: r.name, status: r.status, duration: r.duration_ms.round(2), occurred_at: r.occurred_at,
            user_ref: r.user_ref, tenant: r.app_tenant, exception_preview: r.exception_preview, inertia_component: r.inertia_component,
            queries: r.counters["queries"], deploy: r.deploy }
        end
      end

      # -- Aggregation steps -----------------------------------------------------

      def self.absorb_requests(rows, from, to, q)
        filtered(Telemetry::Execution.requests.between(from, to), q).group(:app_tenant)
          .pluck(:app_tenant, COUNT_SQL, ERRORS_SQL, Arel.sql("AVG(duration)"), Arel.sql("MAX(duration)"), USERS_SQL)
          .each do |tenant, count, errors, avg, max, users|
            rows[tenant].merge!(requests: count, errors: errors, avg: ms(avg), max: ms(max), users: users)
          end
      end

      def self.absorb_jobs(rows, from, to, q)
        filtered(Telemetry::Execution.jobs.between(from, to), q).group(:app_tenant)
          .pluck(:app_tenant, COUNT_SQL, FAILED_SQL)
          .each { |tenant, count, failed| rows[tenant].merge!(jobs: count, failed_jobs: failed) }
      end

      def self.absorb_counts(rows, scope, key)
        scope.group(:app_tenant).count.each { |tenant, count| rows[tenant][key] = count }
      end

      def self.absorb_last_seen(rows, from, to, q)
        filtered(Telemetry::Execution.between(from, to), q).group(:app_tenant).maximum(:occurred_at)
          .each { |tenant, at| rows[tenant][:last_seen_at] = at }
      end

      def self.absorb_sparklines(rows, from, to, q)
        width = bucket_width(from, to, SPARKLINE_BUCKETS)
        counts = filtered(Telemetry::Execution.requests.between(from, to), q).group(:app_tenant, bucket_sql(from, width)).count
        counts.each do |(tenant, index), count|
          rows[tenant][:sparkline][[ index.to_i, SPARKLINE_BUCKETS - 1 ].min] += count
        end
      end

      def self.absorb_p95s(rows, from, to)
        rows.each do |row|
          scope = Telemetry::Execution.requests.between(from, to).where(app_tenant: row[:tenant])
          row[:p95] = p95_ms(scope, row[:requests])
        end
      end

      # -- Helpers ---------------------------------------------------------------

      def self.blank_row(tenant)
        { tenant: tenant, requests: 0, errors: 0, avg: 0.0, max: 0.0, p95: 0.0, jobs: 0, failed_jobs: 0,
          exceptions: 0, logs: 0, users: 0, last_seen_at: nil, sparkline: Array.new(SPARKLINE_BUCKETS, 0) }
      end

      # Tenant-tagged rows only: a NULL app_tenant never matches LIKE either.
      def self.filtered(scope, q)
        return scope.where.not(app_tenant: nil) if q.blank?
        scope.where("app_tenant LIKE ?", "%#{TelemetryRecord.sanitize_sql_like(q.to_s)}%")
      end

      def self.sorted(rows, sort, dir)
        key = SORTS.fetch(sort.to_s, :requests)
        sign = dir.to_s == "asc" ? 1 : -1
        rows.sort_by { |row| row[key] * sign }.first(MAX_TENANTS)
      end

      # The 95th percentile as the duration `count * 5%` rows from the slowest
      # end -- one indexed query, no percentile function needed.
      def self.p95_ms(scope, count)
        return 0.0 if count.to_i.zero?
        ms(scope.order(duration: :desc).offset((count * 0.05).floor).limit(1).pluck(:duration).first)
      end

      def self.grouped_executions(scope, tenant, from, to, error_sql, error_key, limit)
        scope.between(from, to).where(app_tenant: tenant).group(:group_hash, :name)
          .pluck(:group_hash, :name, COUNT_SQL, error_sql, Arel.sql("AVG(duration)"), Arel.sql("MAX(duration)"))
          .map { |group_hash, name, count, errors, avg, max|
            { group_hash: group_hash, name: name, count: count, error_key => errors, avg: ms(avg), max: ms(max) }
          }.sort_by { |row| -row[:count] }.first(limit)
      end

      # Microseconds on the wire, milliseconds in every prop.
      def self.ms(duration)
        duration ? (duration / 1000.0).round(2) : 0.0
      end

      def self.bucket_width(from, to, buckets)
        [ (to - from) / buckets, 1.0 ].max
      end

      # Bucket index per row: epoch seconds since `from` over the bucket width.
      # Windows are an hour or more, so second resolution is plenty.
      # Both interpolations are coerced to numbers first (`from` is a Time, `width`
      # a Float from bucket_width), so the fragment can only ever contain two
      # numeric literals -- never a caller-supplied string.
      def self.bucket_sql(from, width)
        Arel.sql("CAST((strftime('%s', occurred_at) - #{Integer(from.to_i)}) / #{Float(width)} AS INTEGER)")
      end

      # A row landing exactly on `to` indexes one bucket past the end; clamp it
      # into the last one.
      def self.bucket_at(from, width, index, buckets)
        from + ([ index.to_i, buckets - 1 ].min * width)
      end
    end
  end
end
