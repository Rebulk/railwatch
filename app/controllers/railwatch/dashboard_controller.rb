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
    # The bundle's pages are named after the platform's controllers
    # (overview/show, requests/index); strip the engine namespace so
    # default_render finds them.
    inertia_config version: -> { Railwatch::AssetsHelper.digest }, layout: "railwatch/dashboard",
                   use_script_element_for_initial_page: true, always_include_errors_hash: true, default_render: true,
                   component_path_resolver: ->(path:, action:) { "#{path.delete_prefix('railwatch/')}/#{action}" }
    rescue_from Telemetry::CursorPage::InvalidCursor do |exception|
      render plain: exception.message, status: :unprocessable_content
    end

    # The host's resolver, or dashboard_open, or a local environment; anything
    # else is refused before a byte of telemetry is read. See
    # Configuration#dashboard_allowed?.
    before_action :require_dashboard_access
    before_action { Viewer.user = Railwatch.config.resolve_dashboard_user(request) }

    inertia_share auth: -> { { user: Viewer.user.as_json, session: { id: "embedded", recently_authenticated: true } } },
                  account: -> { Railwatch::Embedded::Account.as_json },
                  accounts: -> { [ { id: 1, name: Railwatch::Embedded::Account.name } ] },
                  applications: -> { [ { id: 1, name: Application.current.name, slug: Application.current.slug,
                                       issue_prefix: Application.current.issue_prefix,
                                       environments: [ { id: 1, name: Environment.current.name, slug: Environment.current.slug,
                                                       last_seen_at: Environment.current.last_seen_at, paused: false } ] } ] },
                  flash: -> { { alert: flash.alert, warning: flash[:warning], notice: flash.notice } },
                  google_oauth: false,
                  embedded: true

    private

    def require_dashboard_access
      return if Railwatch.config.dashboard_allowed?(request)

      render plain: "Railwatch: the dashboard is closed. In production, set c.dashboard_user in " \
                    "config/initializers/railwatch.rb to name who is signed in (docs/embedded.md, Authentication), " \
                    "or c.dashboard_open = true to open it to anyone who can reach this URL.",
             status: :forbidden
    end
  end
end
