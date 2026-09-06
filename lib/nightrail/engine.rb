# frozen_string_literal: true

module Nightrail
  class Engine < ::Rails::Engine
    isolate_namespace Nightrail

    config.nightrail = ActiveSupport::OrderedOptions.new

    # The request middleware goes first so wall time includes every other
    # middleware, exactly like Nightwatch's GlobalMiddleware.
    initializer "nightrail.middleware", before: :load_config_initializers do |app|
      app.middleware.insert_before 0, Nightrail::Middleware::Request
    end

    # Before anything subscribes or starts a thread, and after the app's own
    # initializer has had its say about config: a console captures nothing.
    initializer "nightrail.console", after: :load_config_initializers, before: "nightrail.subscribe" do
      Nightrail::Console.silence!
    end

    initializer "nightrail.transport_security", after: :load_config_initializers do
      next if Nightrail.config.ingest_url_allowed?

      Rails.logger.warn(
        "Nightrail will not send telemetry to #{Nightrail.config.ingest_url}: plain HTTP is allowed only for loopback " \
        "hosts unless NIGHTRAIL_ALLOW_HTTP=true"
      )
    end

    # Belt and braces for a console that reaches a prompt some other way than
    # `bin/rails console` (`require "rails/console/app"` then IRB.start, say),
    # where Rails::Console was not yet defined when the initializer above ran.
    # Later, so this one has threads to stop.
    console do
      Nightrail::Console.silence!
    end

    initializer "nightrail.subscribe", after: :load_config_initializers do |app|
      next unless Nightrail.enabled?

      Nightrail::Subscribers.install!(app)
      Nightrail::Patches.install!
    end

    # The process record is written once the app has finished initializing.
    # The after_initialize hook is registered from inside this initializer
    # rather than from the engine's class body (which runs at
    # Bundler.require time, before config/application.rb): hooks run in
    # registration order, so this way it lands after every after_initialize
    # block the app registers from application.rb, its environment files,
    # and config/initializers. boot_seconds covers all of them, and an app
    # that reconfigures Nightrail in its own after_initialize is respected.
    # Each forked child writes its own record from
    # Nightrail.restart_after_fork!.
    initializer "nightrail.process", after: :load_config_initializers do
      config.after_initialize do
        Nightrail::Subscribers::ProcessInfo.record! if Nightrail.enabled?
      end
    end

    # Not gated on Nightrail.enabled?: a rake process runs load_tasks (from
    # the Rakefile) before initialize!, so a token set in
    # config/initializers is not visible yet at that point. Both patches
    # check Nightrail.enabled? on every call and are inert when it is off.
    rake_tasks do
      Nightrail::Patches.install_rake_task!
    end

    runner do
      Nightrail::Patches.install_runner_command!
    end

    # Runs unconditionally (not gated on Nightrail.enabled?) so `Nightrail::Faraday`
    # is a valid constant for apps to reference in their Faraday stack setup
    # regardless of whether Nightrail itself is enabled -- Nightrail.record already
    # no-ops when disabled, so the middleware is inert either way.
    initializer "nightrail.faraday" do
      require "nightrail/faraday" if defined?(::Faraday)
    end

    initializer "nightrail.active_job" do
      ActiveSupport.on_load(:active_job) { include Nightrail::JobTracing }
    end

    initializer "nightrail.action_controller" do
      ActiveSupport.on_load(:action_controller) { include Nightrail::ControllerHelpers }
    end

    initializer "nightrail.shutdown" do
      at_exit { Nightrail.reporter.shutdown if Nightrail.enabled? }
    end

    # Threads do not survive fork. Rails' own ForkTracker (a Process._fork
    # hook, so it sees fork, Process.fork, and Kernel#fork exactly once per
    # child) runs Nightrail.restart_after_fork! in every Puma cluster worker
    # and Solid Queue forked worker: the reporter first, so nothing
    # inherited from the parent can be flushed, then the health sampler and
    # session flusher. Registered whether or not Nightrail is enabled yet --
    # the check is made at fork time, so an app that enables Nightrail late
    # still gets a clean child -- and never allowed to raise: ForkTracker
    # runs its callbacks in order with no rescue, and one that raised would
    # skip every callback after it, including Active Record's pool reset.
    initializer "nightrail.fork" do
      require "active_support/fork_tracker"
      ActiveSupport::ForkTracker.after_fork do
        Nightrail.restart_after_fork! if Nightrail.enabled?
      rescue StandardError => e
        Nightrail.debug { "fork reset failed: #{e.class}: #{e.message}" }
      end
    end

    # Declared after "nightrail.shutdown" (initializers run in declaration
    # order) so its at_exit is registered later and therefore runs first
    # (at_exit is LIFO): the health thread is stopped before the reporter's
    # final flush, not after it.
    initializer "nightrail.health" do
      next unless Nightrail.enabled?

      Nightrail::Health.start!
      at_exit { Nightrail::Health.stop! }
    end

    # Same shape as "nightrail.health": one flusher thread per web process,
    # stopped before the reporter's final flush.
    initializer "nightrail.sessions" do
      next unless Nightrail.enabled? && Nightrail.config.track_sessions

      Nightrail::Sessions.start!
      at_exit { Nightrail::Sessions.stop! }
    end

    # lib/tasks/nightrail_tasks.rake is picked up by Rails::Engine's default
    # lib/tasks convention; the rake_tasks block above only installs the
    # Rake::Task patch.
  end
end

require "nightrail/console"
require "nightrail/health"
require "nightrail/sessions"
require "nightrail/middleware/request"
require "nightrail/job_tracing"
require "nightrail/controller_helpers"
require "nightrail/patches"
