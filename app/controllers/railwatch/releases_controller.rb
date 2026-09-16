# frozen_string_literal: true

# Sentry-style release health: sessions per deploy, and the crash-free rates
# read off them. The release is the deploy string the gem stamps on every
# record it ships, so `show`'s :id is that string rather than a Deploy id.
module Railwatch
    class ReleasesController < DashboardController
    SESSIONS_SHOWN = 50
    RELEASES_SHOWN = 50
    # SQLite reads the deploy back out of an issue's sample payload, which is
    # the release its latest occurrence came from.
    SAMPLE_DEPLOY = "json_extract(sample, '$.deploy') = ?"

    def index
      from, to = window_range
      deploys = environment.deploys.between(from, to).recent.limit(RELEASES_SHOWN).to_a
      new_issues = new_issue_counts(deploys, to)
      summary, series, adoption, health = telemetry do
        [ Telemetry::ReleaseHealth.for_deploy(nil, from, to),
          Telemetry::ReleaseHealth.series(nil, from, to),
          Telemetry::ReleaseHealth.adoption(from, to),
          deploys.to_h { |d| [ d.deploy, Telemetry::ReleaseHealth.for_deploy(d.deploy, from, to) ] } ]
      end
      releases = deploys.map do |d|
        health.fetch(d.deploy).merge(deploy: d.deploy, ref: d.short_ref, name: d.name, deployed_at: d.deployed_at,
                                      adoption: adoption[d.deploy] || 0.0, new_issues: new_issues[d.id].to_i)
      end
      render inertia: { releases: releases, series: series,
                        summary: summary.merge(releases: adoption.count { |_deploy, share| share.positive? }) }
    end

    def show
      release = params[:id]
      deploy = environment.deploys.find_by(deploy: release)
      previous = deploy&.previous_deploy
      from, to = deploy ? deploy.window : window_range
      data = telemetry do
        { summary: Telemetry::ReleaseHealth.for_deploy(release, from, to),
          previous_summary: previous && Telemetry::ReleaseHealth.for_deploy(previous.deploy, *previous.window),
          series: Telemetry::ReleaseHealth.series(release, from, to),
          sessions: Telemetry::Session.where(deploy: release).recent.limit(SESSIONS_SHOWN).map { |s| session_row(s) } }
      end
      render inertia: data.merge(
        release: { deploy: release, ref: deploy&.short_ref || release.first(12), name: deploy&.name, deploy_id: deploy&.id,
                  deployed_at: deploy&.deployed_at, previous_ref: previous&.short_ref },
        range: { from: from.iso8601, to: to.iso8601 },
        new_issues: issue_rows(environment.issues.where(first_seen_at: from..to).or(environment.issues.where(SAMPLE_DEPLOY, release))),
        resolved_issues: issue_rows(environment.issues.where(resolved_in_deploy: release)))
    end

    private

    def session_row(s)
      { id: s.id, session_id: s.session_id, source: s.source, status: s.status, user_ref: s.user_ref,
        duration: s.duration_ms, requests: s.requests, visits: s.visits, errors: s.error_count, occurred_at: s.occurred_at,
        started_at: s.started_at }
    end

    def issue_rows(scope)
      scope.recent.limit(50).map { |i| { id: i.id, key: i.key, title: i.title, status: i.status } }
    end

    # Issues first seen while each release was live -- one query for the table,
    # not one per row. A release is live until the next one deploys.
    def new_issue_counts(deploys, to)
      return {} if deploys.empty?

      ordered = deploys.sort_by(&:deployed_at)
      windows = ordered.each_cons(2).to_h { |release, following| [ release.id, release.deployed_at...following.deployed_at ] }
      windows[ordered.last.id] = ordered.last.deployed_at...to
      first_seen = environment.issues.where(first_seen_at: ordered.first.deployed_at..to).pluck(:first_seen_at)
      windows.transform_values { |window| first_seen.count { |at| window.cover?(at) } }
    end
    end
end
