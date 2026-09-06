# frozen_string_literal: true

module Nightrail
  module Subscribers
    # Shared helpers. Subscribers use ActiveSupport::Notifications event
    # objects (duration in ms, allocations) and must do no I/O.
    module Base
      def subscribe(name, &block)
        ActiveSupport::Notifications.subscribe(name) do |event|
          block.call(event)
        rescue StandardError => e
          subscriber_failed(name, e)
        end
      end

      # For a subscriber that only reads the payload (a counter, say). The
      # five-argument block form makes Rails skip building an Event object
      # -- six clock and GC reads -- for every notification it delivers.
      def subscribe_payload(name, &block)
        ActiveSupport::Notifications.monotonic_subscribe(name) do |_name, _start, _finish, _id, payload|
          block.call(payload)
        rescue StandardError => e
          subscriber_failed(name, e)
        end
      end

      def subscriber_failed(name, error)
        Nightrail.debug { "#{name} subscriber raised #{error.class}: #{error.message}" }
        Nightrail.notify_unrecoverable(error)
      end

      def execution
        Nightrail.execution
      end

      # Whether a child record built now would be kept. With no execution
      # there is nothing to attach it to and Nightrail.push drops it, so the
      # subscriber should not build it in the first place.
      def recording?
        exe = Nightrail.execution
        !exe.nil? && exe.recording?
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
