# frozen_string_literal: true

module Railwatch
  # Base for every dashboard page: the prebuilt Inertia bundle, the shared
  # props its layouts read, and per-controller Inertia config so a host that
  # also uses Inertia keeps its own.
  class DashboardController < ActionController::Base
    include Railwatch::AssetsHelper
    helper Railwatch::AssetsHelper
    include Railwatch::EnvironmentScoped

    layout "railwatch/dashboard"
    inertia_config version: -> { Railwatch::AssetsHelper.digest }, layout: "railwatch/dashboard",
                   use_script_element_for_initial_page: true, always_include_errors_hash: true
    rescue_from Telemetry::CursorPage::InvalidCursor do |exception|
      render plain: exception.message, status: :unprocessable_content
    end

    inertia_share auth: {user: {id: 1, name: "Host User", email: "host@example.com", provider: nil, verified: true,
                                editor: "vscode", editor_root: nil, created_at: Time.current, updated_at: Time.current},
                         session: {id: "embedded", recently_authenticated: true}},
                  account: {id: 1, name: "This app", slug: "app", plan: "embedded"},
                  accounts: [{id: 1, name: "This app"}],
                  applications: -> { [{id: 1, name: environment.application_name, slug: "app", issue_prefix: "APP",
                                       environments: [{id: 1, name: environment.name, slug: environment.slug,
                                                       last_seen_at: environment.last_seen_at, paused: false}]}] },
                  flash: {alert: nil, warning: nil, notice: nil},
                  google_oauth: false

    def show
      requests = grouped("request", limit: 8, order: :p95)
      jobs = grouped("job_attempt", limit: 8)
      render inertia: "overview/show", props: {
        totals: {requests: summary_with_delta("request"), jobs: summary_with_delta("job_attempt")},
        request_series: series("request"), job_series: series("job_attempt"),
        slow_routes: requests, top_jobs: jobs, issues: [], deploys: [], release_health: nil,
        processes: telemetry { Telemetry::Process.recent.limit(20).group_by(&:server).transform_values { |ps| ps.first.slice(:role, :deploy, :ruby_version, :rails_version, :railwatch_version, :booted_at) } }
      }
    end

    def requests
      routes = grouped("request", limit: 200, order: params[:sort], dir: params[:dir])
      routes = apply_request_filters(routes, FilterQuery.parse(params[:q]).fetch(:fields))
      render inertia: "requests/index", props: {routes: routes, series: series("request"), deploys: [],
                                                sort: params[:sort] || "count", dir: params[:dir] || "desc", q: params[:q].to_s}
    end

    def queries
      from, to = window_range
      page_data = nil
      page = lambda do
        page_data ||= telemetry do
          scope = FilterQuery.apply(Telemetry::Query.with_sql, resource: :queries, query: params[:q], from: from, to: to)
          rows, meta = Telemetry::CursorPage.call(scope, cursor: params[:cursor], limit: params[:limit], order: :slowest,
                                                  context: telemetry_cursor_context(:queries))
          [rows.map { |q| query_row(q) }, meta]
        end
      end
      render inertia: "queries/index", props: {
        queries: grouped("query", limit: 200, order: params[:sort], dir: params[:dir]),
        n_plus_ones: [], slowest: InertiaRails.merge { page.call.first }, pagination: -> { page.call.last },
        q: params[:q].to_s, summary: summary_with_delta("query"), sort: params[:sort] || "count", dir: params[:dir] || "desc"
      }
    end

    def stub = show

    private

    def apply_request_filters(routes, fields)
      routes = routes.select { |r| r[:name].start_with?("#{fields['method'].upcase} ") } if fields["method"].present?
      routes = routes.select { |r| r[:name].include?(fields["route"]) } if fields["route"].present?
      routes
    end

    def query_row(q)
      {id: q.id, group_hash: q.group_hash, sql: q.sql.first(2_000), name: q.name, duration: q.duration_ms.round(3),
       occurred_at: q.occurred_at, execution_id: q.execution_id, execution: q.execution_preview, source: q.source,
       connection: q.connection, role: q.role, adapter: q.adapter, deploy: q.deploy, tenant: q.app_tenant, user_ref: q.user_ref,
       explain: q.explain.present?}
    end
  end
end
