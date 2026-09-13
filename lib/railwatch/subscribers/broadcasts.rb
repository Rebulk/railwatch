# frozen_string_literal: true

module Railwatch
  module Subscribers
    # Action Cable broadcasts and transmits. Covers inertia_cable and Turbo
    # Streams since both go through broadcast.action_cable.
    module Broadcasts
      extend Base

      EXECUTION_KEY = :__railwatch_channel_execution

      # An event-object subscriber receives #start before Action Cable invokes
      # the channel method and #finish after it returns or raises. A normal
      # notification block runs only at the end, which is too late for SQL,
      # logs, broadcasts, and transmits inside the action to have a parent.
      class ActionExecution
        def start(_name, _id, payload)
          channel = payload[:channel_class].to_s
          action = payload[:action].to_s
          exe = Railwatch.start_execution(source: :channel_action, sample_kind: :channels,
                                        preview: "#{channel}##{action}")
          # Handed to #finish before anything that could raise. Action Cable
          # workers are a pool: an execution started here and not closed there
          # would stay on Current for whichever channel action that thread
          # picks up next, silently adopting its records.
          payload[EXECUTION_KEY] = exe
          exe.enter_stage(:action)
          exe.user_id = Users.resolve_from_current
        rescue StandardError => e
          Railwatch.debug { "perform_action.action_cable start subscriber raised #{e.class}: #{e.message}" }
          Railwatch.notify_unrecoverable(e)
        end

        def finish(_name, _id, payload)
          exe = payload.delete(EXECUTION_KEY)
          return unless exe

          Railwatch::Current.execution = exe
          exe.finish_stages
          channel = payload[:channel_class].to_s
          action = payload[:action].to_s
          error = payload[:exception_object]
          if error
            Exceptions.capture(error, handled: false, severity: :error,
                               source: "application.action_cable",
                               context: { channel: channel, action: action })
          end
          exe.count(:broadcasts)
          Railwatch.record(:broadcast, group: Record.group_hash(channel, action),
                         timestamp: exe.started_at, kind: "perform_action", channel: channel,
                         action: action, duration: exe.duration, failed: error ? true : false)
          Railwatch.finish_execution(:channel_action, group: Record.group_hash(channel, action),
                                   channel: channel, action: action,
                                   status: error ? "failed" : "processed", failed: error ? true : false)
        rescue StandardError => e
          Railwatch.debug { "perform_action.action_cable finish subscriber raised #{e.class}: #{e.message}" }
          Railwatch.notify_unrecoverable(e)
        ensure
          # ActiveSupport guards subscriber errors, so an internal failure
          # must also restore the execution explicitly rather than leave the
          # worker fiber attached to a completed channel action.
          Railwatch::Current.execution = exe.parent_execution if exe && Railwatch.execution.equal?(exe)
        end
      end

      module_function

      def install!(_app)
        subscribe("broadcast.action_cable") do |event|
          exe = execution
          exe&.count(:broadcasts)
          next unless recording?
          p = event.payload
          stream = p[:broadcasting].to_s
          Railwatch.record(:broadcast,
            group: Record.group_hash(stream_shape(stream)),
            timestamp: started_at(event),
            kind: "broadcast",
            stream: stream[0, 255],
            bytes: (p[:message].to_s.bytesize rescue nil),
            coder: p[:coder]&.name,
            duration: micros(event))
        end

        subscribe("transmit.action_cable") do |event|
          exe = execution
          # Before the recording? gate, like every other counter here: the
          # parent's counters are meant to be true even for a sampled-out
          # execution, so aggregate rates do not depend on the sample rate
          # (docs/records.md, `counters`).
          exe&.count(:broadcasts)
          next unless recording?
          p = event.payload
          Railwatch.record(:broadcast, group: Record.group_hash(p[:channel_class].to_s),
                         timestamp: started_at(event), kind: "transmit", channel: p[:channel_class].to_s,
                         via: p[:via].to_s[0, 255], bytes: (p[:data].to_s.bytesize rescue nil), duration: micros(event))
        end

        ActiveSupport::Notifications.subscribe("perform_action.action_cable", ActionExecution.new)
      end

      def stream_shape(stream)
        stream.gsub(/\b\d+\b/, "?").gsub(/[0-9a-f]{16,}/i, "?")
      end
    end
  end
end
