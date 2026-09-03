# frozen_string_literal: true

module Lantern
  module Subscribers
    # Every cache_*.active_support event. Keys are truncated and vendor
    # prefixes (rack-attack, flipper, solid_cable) are rejected by default.
    module Cache
      extend Base

      EVENTS = {
        "cache_read.active_support" => ->(p) { p[:hit] ? "hit" : "miss" },
        "cache_read_multi.active_support" => ->(_p) { "read_multi" },
        "cache_fetch_hit.active_support" => ->(_p) { "hit" },
        "cache_generate.active_support" => ->(_p) { "generate" },
        "cache_write.active_support" => ->(_p) { "write" },
        "cache_write_multi.active_support" => ->(_p) { "write_multi" },
        "cache_delete.active_support" => ->(_p) { "delete" },
        "cache_delete_multi.active_support" => ->(_p) { "delete_multi" },
        "cache_delete_matched.active_support" => ->(_p) { "delete_matched" },
        "cache_increment.active_support" => ->(_p) { "increment" },
        "cache_decrement.active_support" => ->(_p) { "decrement" },
        "cache_exist?.active_support" => ->(_p) { "exist" }
      }.freeze

      module_function

      def install!(_app)
        EVENTS.each do |name, type_of|
          subscribe(name) do |event|
            p = event.payload
            # cache_read inside a fetch is reported by cache_fetch_hit/generate; skip the inner read.
            next if name == "cache_read.active_support" && p[:super_operation] == :fetch
            key = key_string(p[:key])
            next if ignored_key?(key)
            exe = execution
            exe&.count(:cache_events)
            next unless recording?

            store = p[:store].to_s.demodulize
            Lantern.record(:cache_event,
              group: Record.group_hash(store, key_shape(key)),
              timestamp: started_at(event),
              store: store,
              key: key[0, 255],
              type: type_of.call(p),
              duration: micros(event),
              ttl: p[:expires_in].to_i,
              hits: p[:hits].is_a?(Array) ? p[:hits].size : nil)
          end
        end
      end

      def key_string(key)
        case key
        when Array then key.map { |k| key_string(k) }.join("/")
        when Hash then key.map { |k, v| "#{k}=#{key_string(v)}" }.join("&")
        else
          key.respond_to?(:cache_key) ? key.cache_key : key.to_s
        end
      end

      # Strip ids so "users/123" and "users/456" share a group.
      def key_shape(key)
        key.gsub(/\b\d+\b/, "?").gsub(/[0-9a-f]{16,}/i, "?")
      end

      def ignored_key?(key)
        Lantern.config.ignored_cache_key_prefixes.any? { |pre| key.start_with?(pre) }
      end
    end
  end
end
