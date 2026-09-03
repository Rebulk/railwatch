# frozen_string_literal: true

module Lantern
  module Subscribers
    # Action Cable broadcasts and transmits. Covers inertia_cable and Turbo
    # Streams since both go through broadcast.action_cable.
    module Broadcasts
      extend Base

      module_function

      def install!(_app)
        subscribe("broadcast.action_cable") do |event|
          exe = execution
          exe&.count(:broadcasts)
          next unless recording?
          p = event.payload
          stream = p[:broadcasting].to_s
          Lantern.record(:broadcast,
            group: Record.group_hash(stream_shape(stream)),
            timestamp: started_at(event),
            kind: "broadcast",
            stream: stream[0, 255],
            bytes: (p[:message].to_s.bytesize rescue nil),
            coder: p[:coder]&.name,
            duration: micros(event))
        end

        subscribe("transmit.action_cable") do |event|
          next unless recording?
          p = event.payload
          Lantern.record(:broadcast, group: Record.group_hash(p[:channel_class].to_s),
                         timestamp: started_at(event), kind: "transmit", channel: p[:channel_class].to_s,
                         via: p[:via].to_s[0, 255], bytes: (p[:data].to_s.bytesize rescue nil), duration: micros(event))
        end

        subscribe("perform_action.action_cable") do |event|
          next unless recording?
          p = event.payload
          Lantern.record(:broadcast, group: Record.group_hash(p[:channel_class].to_s, p[:action].to_s),
                         timestamp: started_at(event), kind: "perform_action", channel: p[:channel_class].to_s,
                         action: p[:action].to_s, duration: micros(event))
        end
      end

      def stream_shape(stream)
        stream.gsub(/\b\d+\b/, "?").gsub(/[0-9a-f]{16,}/i, "?")
      end
    end
  end
end
