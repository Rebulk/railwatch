# frozen_string_literal: true

module Railwatch
  # Base for every dashboard page: the prebuilt Inertia bundle, the shared
  # props its layouts read, and per-controller Inertia config so a host that
  # also uses Inertia keeps its own.
  #
  # Inherits from Railwatch.config.base_controller_class (default
  # ActionController::Base) so a host can put its own admin gate in front of
  # every page the way Mission Control Jobs allows: point it at a controller
  # whose before_action requires an admin, and turn HTTP Basic off.
  class DashboardController < Railwatch.config.base_controller_class.constantize
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

    # HTTP Basic, on and closed by default (Configuration#http_basic_auth_*).
    # Runs before anything reads telemetry; a host that authenticates in its
    # base controller or a routes constraint turns it off.
    before_action :authenticate_by_http_basic
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

    def authenticate_by_http_basic
      config = Railwatch.config
      return unless config.http_basic_auth_enabled
      return if config.http_basic_auth_waived?

      if config.http_basic_auth_configured?
        http_basic_authenticate_or_request_with(name: config.http_basic_auth_user, password: config.http_basic_auth_password,
                                                realm: "Railwatch")
      else
        # Closed, not open: same as Mission Control with no credentials. The
        # challenge header is still sent so a client or a monitor sees the
        # scheme, and the body says what to do, since a bare 401 looks like a
        # broken install rather than an unconfigured one.
        response.set_header("WWW-Authenticate", %(Basic realm="Railwatch"))
        render plain: "Railwatch: HTTP Basic authentication is on and no credentials are configured, so the " \
                      "dashboard is closed. Run `bin/rails railwatch:authentication:configure` (writes " \
                      "railwatch.http_basic_auth_user/_password to Rails credentials), or set " \
                      "RAILWATCH_HTTP_BASIC_AUTH_USER and _PASSWORD, or turn Basic off " \
                      "(c.http_basic_auth_enabled = false) once your own auth gates the mount. See docs/embedded.md.",
               status: :unauthorized
      end
    end
  end
end
