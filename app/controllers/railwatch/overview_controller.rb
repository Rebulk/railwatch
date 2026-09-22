# frozen_string_literal: true

module Railwatch
    class OverviewController < DashboardController
    def show
      requests = grouped("request", limit: 8, order: :p95)
      jobs = grouped("job_attempt", limit: 8)
      from, to = window_range
      attention = Railwatch::Attention.new(environment, from: from, to: to, health: Railwatch::MonitoringHealth.new(environment, host: :embedded).summary).to_h
      render inertia: {
        attention: attention,
        totals: { requests: summary_with_delta("request"), jobs: summary_with_delta("job_attempt") },
        request_series: series("request"),
        job_series: series("job_attempt"),
        slow_routes: requests,
        top_jobs: jobs,
        issues: environment.issues.open.recent.limit(8).map { |i| issue_row(i) },
        deploys: deploys_in_window,
        release_health: release_health,
        processes: telemetry { Telemetry::Process.recent.limit(20).group_by(&:server).transform_values { |ps| ps.first.slice(:role, :deploy, :ruby_version, :rails_version, :railwatch_version, :booted_at) } }
      }
    end

    private

    # Crash-free sessions for the release that is live now, over the page's
    # window. nil (and the stat is not rendered) until the environment reports
    # sessions at all.
    def release_health
      deploy = environment.deploys.recent.first or return nil
      health = telemetry { Telemetry::ReleaseHealth.for_deploy(deploy.deploy, *window_range) }
      return nil if health[:crash_free_sessions].nil?
      health.slice(:sessions, :crash_free_sessions).merge(deploy: deploy.deploy, ref: deploy.short_ref)
    end

    def issue_row(i)
      { id: i.id, key: i.key, title: i.title, kind: i.kind, status: i.status, priority: i.priority, occurrences: i.occurrences,
        affected_users: i.affected_users, last_seen_at: i.last_seen_at, culprit: i.culprit }
    end
    end
end
