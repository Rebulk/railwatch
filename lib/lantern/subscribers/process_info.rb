# frozen_string_literal: true

module Lantern
  module Subscribers
    # One `process` record per process boot: role (web / worker / console /
    # command), Ruby and Rails versions, boot time. Gives the platform a
    # server and deploy inventory for free.
    module ProcessInfo
      extend Base

      module_function

      def install!(app)
        @app = app
        @installed = true
        record!
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
          database_adapter: (ActiveRecord::Base.connection_db_config.adapter rescue nil),
          queue_adapter: (ActiveJob::Base.queue_adapter_name rescue nil),
          cache_store: (Rails.cache.class.name rescue nil))
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
