# frozen_string_literal: true

module Lantern
  module Subscribers
    # Noticed gem deliveries, only when the gem is loaded. Noticed delivery
    # methods are Active Jobs, so we hook their perform via the Jobs
    # subscriber and tag them here.
    module Notifications
      extend Base

      module_function

      def install!(_app)
        return unless defined?(::Noticed)

        ActiveSupport::Notifications.subscribe("perform.active_job") do |event|
          job = event.payload[:job]
          next unless job.class.name.to_s.start_with?("Noticed::")
          exe = execution
          exe&.count(:notifications)
          next unless recording?
          Lantern.record(:notification,
            group: Record.group_hash(job.class.name),
            timestamp: started_at(event),
            notifier: (job.arguments.first.is_a?(Hash) ? job.arguments.first[:notification_class] : nil).to_s,
            delivery_method: job.class.name.demodulize,
            duration: micros(event),
            failed: event.payload[:exception].present?)
        rescue StandardError => e
          Lantern.debug { "noticed subscriber: #{e.message}" }
        end
      end
    end
  end
end
