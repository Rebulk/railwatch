# frozen_string_literal: true

module Railwatch
    class JobsController < DashboardController
      include TelemetryIdentity

    def index
      from, to = window_range
      page_data = nil
      page = lambda do
        page_data ||= telemetry do
          scope = FilterQuery.apply(Telemetry::Execution.jobs, resource: :jobs, query: params[:q], from: from, to: to)
          rows, meta = Telemetry::CursorPage.call(scope, cursor: params[:cursor], limit: params[:limit],
            context: telemetry_cursor_context(:jobs))
          people = origin_people(rows)
          [ rows.map { |r| job_row(r, people) }, meta ]
        end
      end
      render inertia: {
        classes: -> { grouped("job_attempt", limit: 200) }, series: -> { series("job_attempt") },
        queues: -> { queue_stats(from, to) }, recent: InertiaRails.merge { page.call.first },
        pagination: -> { page.call.last }, deploys: -> { deploys_in_window }, q: params[:q].to_s
      }
    end

    def klass
      group_hash = params[:group_hash]
      from, to = window_range
      name, attempts = telemetry do
        base = Telemetry::Execution.jobs.where(group_hash: group_hash)
        rows = FilterQuery.apply(base, resource: :jobs,
          query: params[:q], from: from, to: to).recent.limit(200).to_a
        people = origin_people(rows)
        [ base.between(from, to).pick(:name), rows.map { |row| job_row(row, people) } ]
      end
      render inertia: "jobs/klass", props: { name: name, group_hash: group_hash,
                                             summary: summary_with_delta("job_attempt", group_hash: group_hash),
                                             series: series("job_attempt", group_hash: group_hash), attempts: attempts,
                                             deploys: deploys_in_window, q: params[:q].to_s }
    end

    def show
      exe = telemetry { Telemetry::Execution.find_by!(execution_id: params[:id]) }
      render inertia: "executions/show", props: ExecutionPresenter.new(exe, environment).props
    end

    private

    def queue_stats(from, to)
      telemetry do
        Telemetry::Execution.jobs.between(from, to).group(:queue)
          .pluck(:queue, Arel.sql("COUNT(*)"), Arel.sql("AVG(queue_latency)"), Arel.sql("SUM(CASE WHEN outcome = 'failed' THEN 1 ELSE 0 END)"))
          .map { |q, c, lat, f| { queue: q, count: c, avg_latency: (lat.to_f / 1000.0).round(1), failed: f } }
      end
    end

    def job_row(r, people)
      { execution_id: r.execution_id, name: r.name, outcome: r.outcome, queue: r.queue, attempt: r.attempt, duration: r.duration_ms.round(2),
        queue_latency: r.queue_latency && (r.queue_latency / 1000.0).round(1), occurred_at: r.occurred_at, exception_preview: r.exception_preview,
        job_id: r.job_id, deploy: r.deploy }.merge(origin_identity(r, people))
    end
    end
end
