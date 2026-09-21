# frozen_string_literal: true

module Railwatch
    class RequestsController < DashboardController
    def index
      routes = grouped("request", limit: 200, order: params[:sort], dir: params[:dir])
      routes = FilterQuery.filter_routes(routes, params[:q])
      render inertia: { routes: routes, series: series("request"), deploys: deploys_in_window,
                        sort: params[:sort] || "count", dir: params[:dir] || "desc", q: params[:q].to_s }
    end

    # All requests to one route in the window.
    def route
      group_hash = params[:group_hash]
      rows = telemetry { Telemetry::Execution.requests.where(group_hash: group_hash).between(*window_range).recent.limit(200).to_a }
      render inertia: "requests/route", props: {
        route: rows.first&.name || telemetry { Telemetry::Rollup.for_type("request").where(group_hash: group_hash).pick(:name) },
        group_hash: group_hash, summary: summary_with_delta("request", group_hash: group_hash),
        series: series("request", group_hash: group_hash), deploys: deploys_in_window,
        requests: rows.map { |r| execution_row(r) }
      }
    end

    def show
      exe = telemetry { Telemetry::Execution.find_by!(execution_id: params[:id]) }
      render inertia: "executions/show", props: ExecutionPresenter.new(exe, environment).props
    end

    private

    def execution_row(r)
      { execution_id: r.execution_id, name: r.name, status: r.status, duration: r.duration_ms.round(2), occurred_at: r.occurred_at,
        user_ref: r.user_ref, tenant: r.app_tenant, exception_preview: r.exception_preview, inertia_component: r.inertia_component,
        queries: r.counters["queries"], deploy: r.deploy }
    end
    end
end
