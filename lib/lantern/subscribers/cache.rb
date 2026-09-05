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

      # Bounded cache of key => shape, so a given cache key's id-stripping
      # regexes only run once. Keys repeat heavily (same fetch in a loop).
      # The group hash of (store, shape) is cached the same way, per store,
      # so the MD5 also runs once per shape rather than once per event.
      KEY_SHAPE_CACHE_LIMIT = 2_048
      @key_shape_cache = {}
      @key_shape_mutex = Mutex.new
      @group_cache = Hash.new { |h, k| h[k] = {} }

      # Computed once so the hot cache_event record doesn't look this up per call.
      CACHE_EVENT_VERSION = Record::VERSIONS.fetch(:cache_event)

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
            cfg = Lantern.config
            # One hash literal instead of kwargs-packing into Lantern.record --
            # cache_event is a high-frequency type.
            Lantern.push(:cache_event, {
              v: CACHE_EVENT_VERSION,
              t: "cache_event",
              timestamp: started_at(event),
              deploy: cfg.deploy,
              server: cfg.server,
              _group: group_for(store, key_shape(key)),
              **(exe ? exe.envelope : Record::EMPTY_ENVELOPE),
              store: store,
              key: key[0, 255],
              type: p[:exception] ? "fail" : type_of.call(p),
              duration: micros(event),
              ttl: p[:expires_in].to_i,
              hits: p[:hits].is_a?(Array) ? p[:hits].size : nil
            })
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
        cached = @key_shape_cache[key]
        return cached if cached

        shape = key.gsub(/\b\d+\b/, "?").gsub(/[0-9a-f]{16,}/i, "?")
        @key_shape_mutex.synchronize do
          @key_shape_cache.clear if @key_shape_cache.size >= KEY_SHAPE_CACHE_LIMIT
          @key_shape_cache[key] = shape
        end
        shape
      end

      def group_for(store, shape)
        bucket = @group_cache[store]
        cached = bucket[shape]
        return cached if cached

        group = Record.group_hash(store, shape)
        @key_shape_mutex.synchronize do
          bucket.clear if bucket.size >= KEY_SHAPE_CACHE_LIMIT
          bucket[shape] = group
        end
        group
      end

      def ignored_key?(key)
        config = Lantern.config
        return true if config.ignored_cache_key_prefixes.any? { |pattern| Configuration.match_cache_key?(pattern, key) }
        return false if config.capture_default_vendor_cache_keys
        Configuration::DEFAULT_VENDOR_CACHE_KEY.match?(key)
      end
    end
  end
end
