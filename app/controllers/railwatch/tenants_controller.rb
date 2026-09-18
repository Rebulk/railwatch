# frozen_string_literal: true

module Railwatch
    class TenantsController < DashboardController
    def index
      from, to = window_range
      tenants, summary = telemetry do
        rows = Telemetry::Tenant.index(from, to, q: params[:q], sort: params[:sort], dir: params[:dir])
        [ rows, Telemetry::Tenant.overview(rows, from, to) ]
      end
      render inertia: { tenants: tenants, summary: summary,
                        sort: params[:sort] || "requests", dir: params[:dir] || "desc", q: params[:q].to_s }
    end

    # :id is the tenant string. Rails reads a dot in a path segment as a format
    # separator, so tenants like "acme.co" arrive percent-encoded (see the
    # tenants index page's tenantPath).
    def show
      tenant = params[:id]
      from, to = window_range
      data = telemetry do
        { tenant: tenant, summary: { current: Telemetry::Tenant.summary(tenant, from, to),
                                    previous: Telemetry::Tenant.summary(tenant, *previous_window_range) },
          series: Telemetry::Tenant.series(tenant, from, to), routes: Telemetry::Tenant.routes(tenant, from, to),
          jobs: Telemetry::Tenant.job_classes(tenant, from, to), exceptions: Telemetry::Tenant.exceptions(tenant, from, to),
          people: Telemetry::Tenant.people(tenant), recent_requests: Telemetry::Tenant.recent_requests(tenant, from, to) }
      end
      issues = environment.issues.where(group_hash: data[:exceptions].map { |e| e[:group_hash] }.uniq).index_by(&:group_hash)
      render inertia: data.merge(exceptions: data[:exceptions].map { |e| with_issue(e, issues) }, links: links(tenant))
    end

    private

    def with_issue(exception, issues)
      issue = issues[exception[:group_hash]]
      exception.merge(issue_id: issue&.id, issue_key: issue&.key)
    end

    def links(tenant)
      { logs: application_environment_logs_path(application, environment, window: window_key, q: "tenant:#{tenant}"),
        people: application_environment_people_path(application, environment, window: window_key) }
    end
    end
end
