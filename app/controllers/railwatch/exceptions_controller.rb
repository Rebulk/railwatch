# frozen_string_literal: true

module Railwatch
    class ExceptionsController < DashboardController
    def index
      from, to = window_range
      page_data = nil
      page = lambda do
        page_data ||= telemetry do
          scope = FilterQuery.apply(Telemetry::Exception.all, resource: :exceptions, query: params[:q], from: from, to: to)
          recent, pagination = Telemetry::CursorPage.call(scope, cursor: params[:cursor], limit: params[:limit],
            context: telemetry_cursor_context(:exceptions))
          issues_by_group = environment.issues.where(group_hash: recent.map(&:group_hash).uniq).index_by(&:group_hash)
          [ recent.map { |e| exception_row(e, issues_by_group) }, pagination ]
        end
      end
      render inertia: {
        exceptions: InertiaRails.merge { page.call.first }, pagination: -> { page.call.last },
        classes: -> { telemetry { Telemetry::Exception.between(from, to).group(:class_name).count.sort_by { |_class, n| -n }.first(15) } },
        series: -> { telemetry { exception_series(from, to) } },
        total: -> { telemetry { Telemetry::Exception.between(from, to).count } },
        unhandled: -> { telemetry { Telemetry::Exception.between(from, to).unhandled.count } }, q: params[:q].to_s
      }
    end

    private

    def exception_row(e, issues_by_group)
      issue = issues_by_group[e.group_hash]
      { id: e.id, class_name: e.class_name, message: e.message.first(500), handled: e.handled, severity: e.severity, source: e.source,
        file: e.file, line: e.line, occurred_at: e.occurred_at, execution_id: e.execution_id, execution_source: e.execution_source,
        execution_preview: e.execution_preview, user_ref: e.user_ref, group_hash: e.group_hash, issue_id: issue&.id, issue_key: issue&.key }
    end

    # Telemetry::Rollup has no "exception" record type (exceptions carry no
    # duration to absorb), so the chart is a plain bucketed count over the raw
    # table instead of the usual EnvironmentScoped#series.
    # `errors` carries the unhandled count so the chart legend (handled /
    # unhandled) agrees with the Unhandled card above the table.
    def exception_series(from, to)
      step = Telemetry::Aggregations::STEPS.fetch(step_key)
      bucket = Telemetry::Aggregations.bucket_sql("occurred_at", step)
      buckets = Hash.new { |h, k| h[k] = { count: 0, errors: 0 } }
      Telemetry::Exception.between(from, to).group(bucket, :handled).count.each do |(b, handled), c|
        buckets[b][:count] += c
        buckets[b][:errors] += c unless handled
      end
      points = buckets.map { |b, c| { t: Time.at(b).utc, count: c[:count], errors: c[:errors], client_errors: 0, avg: nil, p50: nil, p95: nil, p99: nil } }
      Telemetry::Aggregations.fill(points, from, to, step)
    end
    end
end
