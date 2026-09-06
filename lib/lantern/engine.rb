# frozen_string_literal: true

module Lantern
  class Engine < ::Rails::Engine
    isolate_namespace Lantern

    config.lantern = ActiveSupport::OrderedOptions.new

    # The request middleware goes first so wall time includes every other
    # middleware, exactly like Nightwatch's GlobalMiddleware.
    initializer "lantern.middleware", before: :load_config_initializers do |app|
      app.middleware.insert_before 0, Lantern::Middleware::Request
    end

    # Before anything subscribes or starts a thread, and after the app's own
    # initializer has had its say about config: a console captures nothing.
    initializer "lantern.console", after: :load_config_initializers, before: "lantern.subscribe" do
      Lantern::Console.silence!
    end

    # Belt and braces for a console that reaches a prompt some other way than
    # `bin/rails console` (`require "rails/console/app"` then IRB.start, say),
    # where Rails::Console was not yet defined when the initializer above ran.
    # Later, so this one has threads to stop.
    console do
      Lantern::Console.silence!
    end

    initializer "lantern.subscribe", after: :load_config_initializers do |app|
      next unless Lantern.enabled?

      Lantern::Subscribers.install!(app)
      Lantern::Patches.install!
    end

    # Written after the app has finished initializing rather than from the
    # subscribe initializer, so boot_seconds covers the app's own
    # initializers and the record's first write (which arms the reporter
    # thread) happens after every other initializer has run. Each forked
    # child writes its own from Lantern.restart_after_fork!.
    config.after_initialize do
      Lantern::Subscribers::ProcessInfo.record! if Lantern.enabled?
    end

    rake_tasks do
      Lantern::Patches.install_rake_task! if Lantern.enabled?
    end

    runner do
      Lantern::Patches.install_runner_command! if Lantern.enabled?
    end

    # Runs unconditionally (not gated on Lantern.enabled?) so `Lantern::Faraday`
    # is a valid constant for apps to reference in their Faraday stack setup
    # regardless of whether Lantern itself is enabled -- Lantern.record already
    # no-ops when disabled, so the middleware is inert either way.
    initializer "lantern.faraday" do
      require "lantern/faraday" if defined?(::Faraday)
    end

    initializer "lantern.active_job" do
      ActiveSupport.on_load(:active_job) { include Lantern::JobTracing }
    end

    initializer "lantern.action_controller" do
      ActiveSupport.on_load(:action_controller) { include Lantern::ControllerHelpers }
    end

    initializer "lantern.shutdown" do
      at_exit { Lantern.reporter.shutdown if Lantern.enabled? }
    end

    # Threads do not survive fork. Rails' own ForkTracker (a Process._fork
    # hook, so it sees fork, Process.fork, and Kernel#fork exactly once per
    # child) runs Lantern.restart_after_fork! in every Puma cluster worker
    # and Solid Queue forked worker: the reporter first, so nothing
    # inherited from the parent can be flushed, then the health sampler and
    # session flusher.
    initializer "lantern.fork", after: "lantern.subscribe" do
      next unless Lantern.enabled?

      require "active_support/fork_tracker"
      ActiveSupport::ForkTracker.after_fork { Lantern.restart_after_fork! }
    end

    # Declared after "lantern.shutdown" so its at_exit is registered later and
    # therefore runs first (at_exit is LIFO): the health thread is stopped
    # before the reporter's final flush, not after it.
    initializer "lantern.health", after: "lantern.fork" do
      next unless Lantern.enabled?

      Lantern::Health.start!
      at_exit { Lantern::Health.stop! }
    end

    # Same shape as "lantern.health": one flusher thread per web process,
    # stopped before the reporter's final flush.
    initializer "lantern.sessions", after: "lantern.health" do
      next unless Lantern.enabled? && Lantern.config.track_sessions

      Lantern::Sessions.start!
      at_exit { Lantern::Sessions.stop! }
    end

    # lib/tasks/lantern_tasks.rake is picked up by Rails::Engine's default
    # lib/tasks convention; the rake_tasks block above only installs the
    # Rake::Task patch.
  end
end

require "lantern/console"
require "lantern/health"
require "lantern/sessions"
require "lantern/middleware/request"
require "lantern/job_tracing"
require "lantern/controller_helpers"
require "lantern/patches"
