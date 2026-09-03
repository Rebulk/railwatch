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

    rake_tasks do
      load File.expand_path("../tasks/lantern_tasks.rake", __dir__)
    end
  end
end

require "lantern/middleware/request"
require "lantern/job_tracing"
require "lantern/controller_helpers"
require "lantern/patches"
