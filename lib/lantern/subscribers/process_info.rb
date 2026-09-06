# frozen_string_literal: true

module Lantern
  module Subscribers
    # One `process` record per process boot: role (web / worker / console /
    # command), Ruby and Rails versions, boot time. Gives the platform a
    # server and deploy inventory for free.
    module ProcessInfo
      extend Base

      module_function

      # Registers only. The record itself is written from the engine's
      # after_initialize, once the app is fully booted, so boot_seconds
      # covers the app's own initializers rather than stopping short of
      # them.
      def install!(app)
        @app = app
        @installed = true
      end

      def restart_after_fork!
        record! if @installed
      end

      def record!
        boot = Clock.monotonic - Lantern::BOOTED_AT
        Lantern.record(:process,
          pid: Process.pid,
          role: role,
          ruby_version: RUBY_VERSION,
          rails_version: (Rails.version rescue nil),
          lantern_version: Lantern::VERSION,
          app: @app&.class&.module_parent_name,
          environment: Lantern.config.environment_name,
          boot_seconds: boot,
          database_adapter: database_adapter,
          queue_adapter: queue_adapter,
          cache_store: (Rails.cache.class.name rescue nil))
      end

      # Resolved from the app's configuration with Rails' own resolvers
      # rather than through ActiveRecord::Base / ActiveJob::Base: in a
      # lazy-loading process (development, or a production boot without
      # eager loading) touching those constants is what loads the
      # frameworks, some 350 ms of boot nothing else asked for. Both
      # resolvers are requirable on their own.
      def database_adapter
        config = @app&.config&.database_configuration or return nil
        require "active_record/database_configurations"
        # Keyed by Rails.env, as Active Record itself does; DATABASE_URL and
        # `url:` entries are resolved the same way it resolves them.
        ActiveRecord::DatabaseConfigurations.new(config).find_db_config(Rails.env)&.adapter
      rescue StandardError
        nil
      end

      def queue_adapter
        adapter = @app&.config&.active_job&.queue_adapter or return nil
        return adapter.to_s if adapter.is_a?(Symbol) || adapter.is_a?(String)

        require "active_job/queue_adapter"
        ActiveJob.adapter_name(adapter).underscore
      rescue StandardError
        nil
      end

      # Puma is loaded in every process of an app that bundles it, so a Solid
      # Queue worker is recognised first, by how it was started (bin/jobs or
      # `rake solid_queue:start`).
      def role
        if defined?(::SolidQueue) && ($PROGRAM_NAME.include?("jobs") || ARGV.first.to_s.start_with?("solid_queue:")) then "worker"
        elsif defined?(::Rails::Console) then "console"
        elsif $PROGRAM_NAME.end_with?("rake") then "command"
        elsif defined?(::Puma) then "web"
        else "process"
        end
      end
    end
  end
end
