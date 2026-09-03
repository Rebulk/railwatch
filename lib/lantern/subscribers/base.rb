# frozen_string_literal: true

module Lantern
  module Subscribers
    # Shared helpers. Subscribers use ActiveSupport::Notifications event
    # objects (duration in ms, allocations) and must do no I/O.
    module Base
      def subscribe(name, &block)
        ActiveSupport::Notifications.subscribe(name) do |event|
          block.call(event)
        rescue StandardError => e
          Lantern.debug { "#{name} subscriber raised #{e.class}: #{e.message}" }
          Lantern.notify_unrecoverable(e)
        end
      end

      def execution
        Lantern.execution
      end

      def recording?
        exe = Lantern.execution
        exe.nil? || exe.recording?
      end

      def micros(event)
        Clock.ms_to_micros(event.duration)
      end

      def started_at(event)
        # event.time is monotonic in Rails >= 7; derive wall time from now minus duration.
        Clock.now - (event.duration / 1_000.0)
      end
    end
  end
end
