# frozen_string_literal: true

# The dashboard controllers are Inertia controllers; a host that does not use
# Inertia itself never requires the gem, so the engine does.
require "inertia_rails"
# The engine's jobs (grouping, rollups, scans) are Active Job classes even
# though embedded mode calls their perform directly, so a host built with
# `rails new --minimal` (no Active Job) still needs the framework loaded.
# Part of the rails gem this one depends on, so nothing new is pulled in.
require "active_job/railtie"

module Railwatch
  # isolate_namespace would give every model a railwatch_ prefix. Only the
  # engine's own records (issues, comments, deploys: Railwatch::ApplicationRecord)
  # carry it; the telemetry tables are the hosted platform's schema and stay
  # unprefixed. Defined before isolate_namespace runs, which only adds a
  # prefix when none is set.
  def self.table_name_prefix = ""

  class Engine < ::Rails::Engine
    isolate_namespace Railwatch

    config.railwatch = ActiveSupport::OrderedOptions.new

    # The dashboard bundle is built into the gem at release time; serve it
    # from here so a host app needs no asset pipeline integration at all.
    # Where it goes in the stack is DashboardAssets.install!'s decision.
    initializer "railwatch.dashboard_assets" do |app|
      Railwatch::DashboardAssets.install!(app, root: root.join("public/railwatch").to_s)
    end

    # Action Cable is optional: live dashboard updates need it, nothing else
    # does. A host without it (`rails new --minimal`, --skip-action-cable)
    # must not eager-load the engine's channel, which inherits from a class
    # that does not exist there.
    initializer "railwatch.channels", before: :setup_main_autoloader do
      Rails.autoloaders.main.ignore(root.join("app/channels")) unless defined?(::ActionCable)
    end

    # The dashboard bundle subscribes to "EnvironmentChannel" by name; Action
    # Cable constantizes that, so the engine's channel needs the bare name.
    # Only defined when the host has not got one of its own.
    initializer "railwatch.live_channel" do
      next unless defined?(::ActionCable)

      # Action Cable constantizes the subscription's channel name at
      # subscribe time; the alias only has to exist by then, and it must
      # not clobber a host channel of the same name.
      config.to_prepare do
        Object.const_set(:EnvironmentChannel, Railwatch::EnvironmentChannel) unless Object.const_defined?(:EnvironmentChannel)
      end
    end

    # The request middleware goes first so wall time includes every other
    # middleware, exactly like Nightwatch's GlobalMiddleware.
    initializer "railwatch.middleware", before: :load_config_initializers do |app|
      app.middleware.insert_before 0, Railwatch::Middleware::Request
    end

    # HTTP installs have no embedded databases or job backend. Loading their
    # models still registers them with Active Record, whose schema-cache boot
    # hook asks every descendant for its connection_pool (e.g. with
    # activerecord-tenanted). Decide after the host's initializer selects the
    # transport. Keep autoloading available for the local installer and tools;
    # only local installs should eagerly load the embedded models and jobs.
    # Dashboard controllers also reference model constants in their class
    # bodies. The beacon is the only controller a cloud install needs.
    initializer "railwatch.embedded_eager_loading", after: :load_config_initializers, before: :setup_main_autoloader do
      next if Railwatch.config.local?

      Rails.autoloaders.main.do_not_eager_load(root.join("app/models"))
      Rails.autoloaders.main.do_not_eager_load(root.join("app/jobs"))
      root.glob("app/controllers/railwatch/*.rb").each do |path|
        Rails.autoloaders.main.do_not_eager_load(path) unless path.basename.to_s == "beacon_controller.rb"
      end
    end

    # Before anything subscribes or starts a thread, and after the app's own
    # initializer has had its say about config: a console captures nothing.
    initializer "railwatch.console", after: :load_config_initializers, before: "railwatch.subscribe" do
      Railwatch::Console.silence!
    end

    # Same source Mission Control Jobs reads: railwatch.http_basic_auth_user
    # and _password in Rails credentials, which `bin/rails
    # railwatch:authentication:configure` writes. An initializer or env var
    # that already set them wins.
    initializer "railwatch.http_basic_auth", after: :load_config_initializers do |app|
      config = Railwatch.config
      config.http_basic_auth_user ||= app.credentials.dig(:railwatch, :http_basic_auth_user)
      config.http_basic_auth_password ||= app.credentials.dig(:railwatch, :http_basic_auth_password)
    end

    # Two things worth one line in the log at boot, because both are
    # invisible until something is already wrong: a Rails/json pair that
    # cannot decode, and an embedded dashboard with nothing declared in
    # front of it.
    initializer "railwatch.warnings", after: :load_config_initializers do
      config.after_initialize do
        next unless Railwatch.enabled?

        Rails.logger.warn("[railwatch] #{Railwatch::JsonCompat.advice}") if Railwatch::JsonCompat.broken?

        if Railwatch.config.local? && Railwatch.config.dashboard_gate == :undeclared && !Rails.env.local?
          Rails.logger.warn(
            "[railwatch] the dashboard at the engine's mount has no gate this gem can see: HTTP Basic is off and " \
            "no base_controller_class, dashboard_user or dashboard_open is set. If a routes constraint or your " \
            "network already gates it, set `c.dashboard_open = true` to say so (it also enables live updates); " \
            "otherwise anyone who can reach the URL can read every query, log line and exception this app records."
          )
        end
      end
    end

    initializer "railwatch.transport_security", after: :load_config_initializers do
      next if Railwatch.config.local? || Railwatch.config.ingest_url_allowed?

      Rails.logger.warn(
        "Railwatch will not send telemetry to #{Railwatch.config.ingest_url}: plain HTTP is allowed only for loopback " \
        "hosts unless RAILWATCH_ALLOW_HTTP=true"
      )
    end

    # Belt and braces for a console that reaches a prompt some other way than
    # `bin/rails console` (`require "rails/console/app"` then IRB.start, say),
    # where Rails::Console was not yet defined when the initializer above ran.
    # Later, so this one has threads to stop.
    console do
      Railwatch::Console.silence!
    end

    initializer "railwatch.subscribe", after: :load_config_initializers do |app|
      next unless Railwatch.enabled?

      Railwatch::Subscribers.install!(app)
      Railwatch::Patches.install!
    end

    # The process record is written once the app has finished initializing.
    # The after_initialize hook is registered from inside this initializer
    # rather than from the engine's class body (which runs at
    # Bundler.require time, before config/application.rb): hooks run in
    # registration order, so this way it lands after every after_initialize
    # block the app registers from application.rb, its environment files,
    # and config/initializers. boot_seconds covers all of them, and an app
    # that reconfigures Railwatch in its own after_initialize is respected.
    # Each forked child writes its own record from
    # Railwatch.restart_after_fork!.
    initializer "railwatch.process", after: :load_config_initializers do
      config.after_initialize do
        Railwatch::Subscribers::ProcessInfo.record! if Railwatch.enabled?
      end
    end

    # Not gated on Railwatch.enabled?: a rake process runs load_tasks (from
    # the Rakefile) before initialize!, so a token set in
    # config/initializers is not visible yet at that point. Both patches
    # check Railwatch.enabled? on every call and are inert when it is off.
    rake_tasks do
      Railwatch::Patches.install_rake_task!
    end

    runner do
      Railwatch::Patches.install_runner_command!
    end

    # Runs unconditionally (not gated on Railwatch.enabled?) so `Railwatch::Faraday`
    # is a valid constant for apps to reference in their Faraday stack setup
    # regardless of whether Railwatch itself is enabled -- Railwatch.record already
    # no-ops when disabled, so the middleware is inert either way.
    initializer "railwatch.faraday" do
      require "railwatch/faraday" if defined?(::Faraday)
    end

    initializer "railwatch.active_job" do
      ActiveSupport.on_load(:active_job) { include Railwatch::JobTracing }
    end

    initializer "railwatch.action_controller" do
      ActiveSupport.on_load(:action_controller) { include Railwatch::ControllerHelpers }
    end

    initializer "railwatch.shutdown" do
      at_exit { Railwatch.reporter.shutdown if Railwatch.enabled? }
    end

    # Threads do not survive fork. Rails' own ForkTracker (a Process._fork
    # hook, so it sees fork, Process.fork, and Kernel#fork exactly once per
    # child) runs Railwatch.restart_after_fork! in every Puma cluster worker
    # and Solid Queue forked worker: the reporter first, so nothing
    # inherited from the parent can be flushed, then the health sampler and
    # session flusher. Registered whether or not Railwatch is enabled yet --
    # the check is made at fork time, so an app that enables Railwatch late
    # still gets a clean child -- and never allowed to raise: ForkTracker
    # runs its callbacks in order with no rescue, and one that raised would
    # skip every callback after it, including Active Record's pool reset.
    initializer "railwatch.fork" do
      require "active_support/fork_tracker"
      ActiveSupport::ForkTracker.after_fork do
        Railwatch.restart_after_fork! if Railwatch.enabled?
      rescue StandardError => e
        Railwatch.debug { "fork reset failed: #{e.class}: #{e.message}" }
      end
    end

    # Declared after "railwatch.shutdown" (initializers run in declaration
    # order) so its at_exit is registered later and therefore runs first
    # (at_exit is LIFO): the health thread is stopped before the reporter's
    # final flush, not after it.
    initializer "railwatch.health" do
      next unless Railwatch.enabled?

      Railwatch::Health.start!
      at_exit { Railwatch::Health.stop! }
    end

    # Same shape as "railwatch.health": one flusher thread per web process,
    # stopped before the reporter's final flush.
    initializer "railwatch.sessions" do
      next unless Railwatch.enabled? && Railwatch.config.track_sessions

      Railwatch::Sessions.start!
      at_exit { Railwatch::Sessions.stop! }
    end

    # The embedded install's maintenance clock (release health, scans,
    # pruning). Same shape and ordering rationale as "railwatch.health":
    # stopped before the reporter's final flush. Maintenance.start! is a
    # no-op unless the transport is local.
    initializer "railwatch.maintenance" do
      next unless Railwatch.enabled?

      Railwatch::Maintenance.start!
      at_exit { Railwatch::Maintenance.stop! }
    end

    # Draining the export queue. Same shape and ordering as the others:
    # stopped before the reporter's final flush, so its last claim is
    # released rather than left to expire. Sender.start! is a no-op unless
    # export is configured and usable.
    initializer "railwatch.export" do
      next unless Railwatch.enabled?

      Railwatch::Export::Sender.start!
      at_exit { Railwatch::Export::Sender.stop! }
    end

    # lib/tasks/railwatch_tasks.rake is picked up by Rails::Engine's default
    # lib/tasks convention; the rake_tasks block above only installs the
    # Rake::Task patch.
  end
end

require "railwatch/console"
require "railwatch/health"
require "railwatch/sessions"
require "railwatch/maintenance"
require "railwatch/middleware/request"
require "railwatch/job_tracing"
require "railwatch/controller_helpers"
require "railwatch/patches"
