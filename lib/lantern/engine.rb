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

    # Declared after "lantern.shutdown" so its at_exit is registered later and
    # therefore runs first (at_exit is LIFO): the health thread is stopped
    # before the reporter's final flush, not after it.
    initializer "lantern.health", after: "lantern.subscribe" do
      next unless Lantern.enabled?

      Lantern::Health.start!
      at_exit { Lantern::Health.stop! }
      # Threads do not survive fork: re-arm the sampler in every child (Puma
      # cluster workers, Solid Queue forked workers).
      ::Process.singleton_class.prepend(Lantern::Health::ForkHook)
    end

    # Same shape as "lantern.health": one flusher thread per web process,
    # stopped before the reporter's final flush, re-armed after a fork.
    initializer "lantern.sessions", after: "lantern.subscribe" do
      next unless Lantern.enabled? && Lantern.config.track_sessions

      Lantern::Sessions.start!
      at_exit { Lantern::Sessions.stop! }
      ::Process.singleton_class.prepend(Lantern::Sessions::ForkHook)
    end

    # lib/tasks/lantern_tasks.rake is already picked up by Rails::Engine's
    # default lib/tasks convention (Rails::Engine#run_tasks_blocks), so no
    # explicit rake_tasks registration is needed here.
  end
end

require "lantern/console"
require "lantern/health"
require "lantern/sessions"
require "lantern/middleware/request"
require "lantern/job_tracing"
require "lantern/controller_helpers"
require "lantern/patches"
