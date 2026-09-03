# frozen_string_literal: true

module Lantern
  module Subscribers
    # Template, partial, and collection renders. Only the first N per
    # execution are stored (config.max_view_renders_per_execution); all are counted.
    module Views
      extend Base

      module_function

      def install!(_app)
        %w[render_template render_partial render_collection render_layout].each do |kind|
          subscribe("#{kind}.action_view") do |event|
            exe = execution
            exe&.count(:view_renders)
            next unless recording?
            next if exe && exe.counters[:view_renders] > Lantern.config.max_view_renders_per_execution
            p = event.payload
            identifier = p[:identifier].to_s.delete_prefix(Backtrace.app_root)
            Lantern.record(:view_render,
              group: Record.group_hash(identifier),
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
