# frozen_string_literal: true

module Railwatch
  module Subscribers
    # One `process` record per process boot: role (web / worker / console /
    # command), Ruby and Rails versions, boot time. Gives the platform a
    # server and deploy inventory for free.
    module ProcessInfo
      extend Base

      module_function

      # Keeps the app; the record itself is written from the engine's
      # after_initialize, once the app is fully booted, so boot_seconds
      # covers the app's own initializers rather than stopping short of
      # them.
      def install!(app)
        @app = app
        @database_adapter = nil
      end

      def restart_after_fork!
        record!
      end

      def record!
        boot = Clock.monotonic - Railwatch::BOOTED_AT
        Railwatch.record(:process,
          pid: Process.pid,
          role: role,
          ruby_version: RUBY_VERSION,
          rails_version: (Rails.version rescue nil),
          railwatch_version: Railwatch::VERSION,
          app: @app&.class&.module_parent_name,
          environment: Railwatch.config.environment_name,
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
      # Memoised: database.yml is re-read and re-rendered on every
      # database_configuration call, and the adapter cannot change across a
      # fork. Keyed by Rails.env, as Active Record itself does; DATABASE_URL
      # and `url:` entries are resolved the same way it resolves them.
      def database_adapter
        @database_adapter ||= begin
          config = @app&.config&.database_configuration
          if config
            require "active_record/database_configurations"
            ActiveRecord::DatabaseConfigurations.new(config).find_db_config(Rails.env)&.adapter
          end
        rescue StandardError
          nil
        end
      end

      # The effective adapter lives on ActiveJob::Base, which an app may set
      # directly in an initializer; it is read from there whenever the
      # framework is already loaded (any eager-loaded app with jobs), and
      # from configuration otherwise, so a lazy boot does not load Active
      # Job for one string.
      def queue_adapter
        return ActiveJob::Base.queue_adapter_name if ActiveJob.autoload?(:Base).nil?

        configured_queue_adapter
      rescue StandardError
        nil
      end

      def configured_queue_adapter
        adapter = @app&.config&.active_job&.queue_adapter or return nil
        return adapter.to_s if adapter.is_a?(Symbol) || adapter.is_a?(String)

        require "active_job/queue_adapter"
        ActiveJob.adapter_name(adapter).underscore
      end

      # Puma is loaded in every process of an app that bundles it, so a Solid
      # Queue worker is recognised first, by how it was started (bin/jobs or
      # `rake solid_queue:start`) or by the procline Solid Queue gives every
      # process it forks ("solid-queue-worker(1.7.0): ..."), which replaces
      # $PROGRAM_NAME after boot and would otherwise turn the supervisor,
      # dispatcher, and scheduler into "web" on every health sample.
      def role
        if defined?(Railwatch::Writer) && Railwatch::Writer.running? then "writer"
        elsif defined?(::SolidQueue) && ($PROGRAM_NAME.include?("jobs") || $PROGRAM_NAME.start_with?("solid-queue-") || ARGV.first.to_s.start_with?("solid_queue:")) then "worker"
        elsif defined?(::Rails::Console) then "console"
        elsif $PROGRAM_NAME.end_with?("rake") then "command"
        elsif defined?(::Puma) then "web"
        else "process"
        end
      end
    end
  end
end
