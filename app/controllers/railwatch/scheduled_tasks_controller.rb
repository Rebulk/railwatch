# frozen_string_literal: true

module Railwatch
    class ScheduledTasksController < DashboardController
      include TelemetryIdentity

    def index
      from, to = window_range
      tasks = telemetry do
        rows = Telemetry::Execution.scheduled.between(from, to).group(:task_key)
          .pluck(:task_key, Arel.sql("COUNT(*)"), Arel.sql("SUM(CASE WHEN outcome = 'failed' THEN 1 ELSE 0 END)"), Arel.sql("AVG(duration)"), Arel.sql("MAX(occurred_at)"))
        schedules = Telemetry::Execution.latest_schedules(rows.map(&:first))
        rows.map { |k, c, f, d, last| { task_key: k, runs: c, failed: f, avg: (d.to_f / 1000.0).round(1), last_run_at: last, schedule: schedules[k] } }
      end
      tasks.each { |t| t[:next_run_at] = next_run(t[:schedule]) }
      recent = telemetry do
        rows = Telemetry::Execution.scheduled.between(from, to).recent.limit(100).to_a
        people = origin_people(rows)
        rows.map do |row|
          { execution_id: row.execution_id, task_key: row.task_key, name: row.name, outcome: row.outcome,
           duration: row.duration_ms.round(1), occurred_at: row.occurred_at,
           exception_preview: row.exception_preview }.merge(origin_identity(row, people))
        end
      end
      render inertia: { tasks: tasks, runs: recent, missed: environment.issues.open.where("group_hash LIKE 'missed:%'").map { |i| { key: i.key, title: i.title, id: i.id } } }
    end

    def show
      exe = telemetry { Telemetry::Execution.find_by!(execution_id: params[:id]) }
      render inertia: "executions/show", props: ExecutionPresenter.new(exe, environment).props
    end

    private

    # Solid Queue schedules are cron or natural language ("every 5 minutes"),
    # both of which fugit parses; anything it can't parse has no next run.
    def next_run(schedule)
      return nil if schedule.blank?
      require "fugit"
      Fugit.parse(schedule)&.next_time&.to_t
    rescue StandardError
      nil
    end
    end
end
