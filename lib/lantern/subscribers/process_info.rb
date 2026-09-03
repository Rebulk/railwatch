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
        boot = defined?(Rails) && Rails.respond_to?(:application) ? (Clock.now - $PROGRAM_START_TIME.to_f rescue nil) : nil
        Lantern.record(:process,
          pid: Process.pid,
          role: role,
          ruby_version: RUBY_VERSION,
          rails_version: (Rails.version rescue nil),
          lantern_version: Lantern::VERSION,
          app: app&.class&.module_parent_name,
          environment: Lantern.config.environment_name,
          boot_seconds: boot,
          database_adapter: (ActiveRecord::Base.connection_db_config.adapter rescue nil),
          queue_adapter: (ActiveJob::Base.queue_adapter_name rescue nil),
          cache_store: (Rails.cache.class.name rescue nil))
      end

      def role
        if defined?(::Puma) then "web"
        elsif defined?(::SolidQueue::Supervisor) && $PROGRAM_NAME.include?("jobs") then "worker"
        elsif defined?(::Rails::Console) then "console"
        elsif $PROGRAM_NAME.end_with?("rake") then "command"
        else "process"
        end
      end
    end
  end
end
