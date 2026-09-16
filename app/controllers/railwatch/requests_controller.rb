# frozen_string_literal: true

module Railwatch
    class RequestsController < DashboardController
    def index
      routes = grouped("request", limit: 200, order: params[:sort], dir: params[:dir])
      routes = apply_filters(routes, FilterQuery.parse(params[:q]).fetch(:fields))
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

    # Rollup rows for "request" carry no raw status codes, only aggregated
    # count/errors/client_errors, so status:5xx etc. is a family match against
    # those buckets rather than an exact code lookup.
    def apply_filters(routes, fields)
      routes = routes.select { |r| r[:name].start_with?("#{fields['method'].upcase} ") } if fields["method"].present?
      routes = routes.select { |r| r[:name].include?(fields["route"]) } if fields["route"].present?
      if (range = FilterQuery.status_range(fields["status"]))
        routes = routes.select do |r|
          case range.begin
          when 500..599 then r[:errors].positive?
          when 400..499 then r[:client_errors].positive?
          else (r[:count] - r[:errors] - r[:client_errors]).positive?
          end
        end
      end
      routes
    end

    def execution_row(r)
      { execution_id: r.execution_id, name: r.name, status: r.status, duration: r.duration_ms.round(2), occurred_at: r.occurred_at,
        user_ref: r.user_ref, tenant: r.app_tenant, exception_preview: r.exception_preview, inertia_component: r.inertia_component,
        queries: r.counters["queries"], deploy: r.deploy }
    end
    end
end
