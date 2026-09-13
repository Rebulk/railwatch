# frozen_string_literal: true

module Railwatch
  module Subscribers
    # Template, partial, and collection renders. Only the first N per
    # execution are stored (config.max_view_renders_per_execution); all are counted.
    module Views
      extend Base

      # A process renders a small, fixed set of templates, so the identifier
      # -> group hash is computed once per template rather than per render.
      # Frozen because the same string goes out on every record as _group.
      GROUP_CACHE_LIMIT = 2_048
      @group_cache = {}
      @group_mutex = Mutex.new

      module_function

      def group_for(identifier)
        cached = @group_cache[identifier]
        return cached if cached

        group = Record.group_hash(identifier).freeze
        @group_mutex.synchronize do
          @group_cache.clear if @group_cache.size >= GROUP_CACHE_LIMIT
          @group_cache[identifier] = group
        end
        group
      end

      def install!(_app)
        %w[render_template render_partial render_collection render_layout].each do |kind|
          subscribe("#{kind}.action_view") do |event|
            exe = execution
            exe&.count(:view_renders)
            next unless recording?
            next if exe && exe.counters[:view_renders] > Railwatch.config.max_view_renders_per_execution
            p = event.payload
            identifier = p[:identifier].to_s.delete_prefix(Backtrace.app_root)
            Railwatch.record(:view_render,
              group: group_for(identifier),
              timestamp: started_at(event),
              identifier: identifier[0, 255],
              kind: kind.delete_prefix("render_"),
              layout: p[:layout]&.to_s,
              count: p[:count],
              cache_hits: p[:cache_hits],
              duration: micros(event))
          end
        end
      end
    end
  end
end
