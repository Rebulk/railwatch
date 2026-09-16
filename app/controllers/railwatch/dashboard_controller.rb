# frozen_string_literal: true

module Railwatch
  # Experiment: renders one real dashboard page from the prebuilt bundle,
  # with the shared props the layouts read, inside a host app that has no
  # Node, no Vite, and no Inertia of its own. Props are stubbed; the point
  # is the delivery path, not the data.
  class DashboardController < ActionController::Base
    include Railwatch::AssetsHelper
    helper Railwatch::AssetsHelper

    layout "railwatch/dashboard"
    # Scoped to this controller subtree: a host that also uses Inertia keeps
    # its own global version, layout and parent controller.
    # use_script_element_for_initial_page must match the bundle: the client is
    # built with that flag on and reads the page from a <script> element, not
    # a data-page attribute.
    inertia_config version: -> { Railwatch::AssetsHelper.digest }, layout: "railwatch/dashboard",
                   use_script_element_for_initial_page: true, always_include_errors_hash: true

    inertia_share auth: {user: {id: 1, name: "Host User", email: "host@example.com", provider: nil, verified: true,
                                editor: "vscode", editor_root: nil, created_at: Time.current, updated_at: Time.current},
                         session: {id: "embedded", recently_authenticated: true}},
                  account: {id: 1, name: "This app", slug: "app", plan: "embedded"},
                  accounts: [{id: 1, name: "This app"}],
                  applications: [{id: 1, name: "This app", slug: "app", issue_prefix: "APP",
                                  environments: [{id: 1, name: Rails.env, slug: "app-#{Rails.env}", last_seen_at: Time.current, paused: false}]}],
                  environment: {id: 1, name: Rails.env, slug: "app-#{Rails.env}", application_id: 1, application_name: "This app",
                                issue_prefix: "APP", last_seen_at: Time.current, paused: false, token_prefix: "rw_embedded",
                                repository_url: nil, default_branch: "main"},
                  window: "24h",
                  range: {from: 24.hours.ago.iso8601(6), to: Time.current.iso8601(6)},
                  saved_views: [],
                  flash: {alert: nil, warning: nil, notice: nil},
                  google_oauth: false

    def show
      render inertia: "overview/show", props: {
        totals: {requests: {current: zero, previous: zero}, jobs: {current: zero, previous: zero}},
        request_series: [], job_series: [], slow_routes: [], top_jobs: [], issues: [], deploys: [],
        release_health: nil, processes: {}
      }
    end

    def requests
      render inertia: "requests/index", props: {routes: [], series: [], deploys: [], sort: "count", dir: "desc", q: ""}
    end

    def stub
      render inertia: "overview/show", props: {
        totals: {requests: {current: zero, previous: zero}, jobs: {current: zero, previous: zero}},
        request_series: [], job_series: [], slow_routes: [], top_jobs: [], issues: [], deploys: [],
        release_health: nil, processes: {}
      }
    end

    private

    def zero = {count: 0, errors: 0, client_errors: 0, avg: 0, p50: 0, p95: 0, p99: 0, max: 0}
  end
end
