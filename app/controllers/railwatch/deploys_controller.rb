# frozen_string_literal: true

module Railwatch
    class DeploysController < DashboardController
    def index
      render inertia: { deploys: environment.deploys.recent.limit(100).map { |d| deploy_row(d) } }
    end

    # Before/after comparison: the hour before the deploy versus the hour after.
    def show
      deploy = environment.deploys.find(params[:id])
      before = [ deploy.deployed_at - 1.hour, deploy.deployed_at ]
      after = [ deploy.deployed_at, deploy.deployed_at + 1.hour ]
      compare, health = telemetry do
        [ %w[request job_attempt].to_h do |type|
          [ type, { before: Telemetry::Rollup.summarize(Telemetry::Rollup.for_type(type).where(bucket: before.first.beginning_of_hour..before.last)),
                    after: Telemetry::Rollup.summarize(Telemetry::Rollup.for_type(type).where(bucket: after.first.beginning_of_hour..after.last)) } ]
        end, Telemetry::ReleaseHealth.for_deploy(deploy.deploy, *deploy.window) ]
      end
      new_issues = environment.issues.where(first_seen_at: after.first..after.last + 23.hours).recent.map { |i| { id: i.id, key: i.key, title: i.title, status: i.status } }
      resolved = environment.issues.where(resolved_in_deploy: deploy.deploy).map { |i| { id: i.id, key: i.key, title: i.title } }
      render inertia: { deploy: deploy_row(deploy).merge(commits: deploy.commits, previous_ref: deploy.previous_ref,
                          repository_ref: deploy.ref, detail: deploy.detail),
                        compare: compare, health: health, new_issues: new_issues, resolved_issues: resolved }
    end

    private

    def deploy_row(d)
      { id: d.id, deploy: d.deploy, ref: d.short_ref, name: d.name, url: d.url, server: d.server, deployed_at: d.deployed_at,
        commits_count: d.commits_count, performer: d.detail["performer"] }
    end
    end
end
