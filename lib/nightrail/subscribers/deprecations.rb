# frozen_string_literal: true

module Nightrail
  module Subscribers
    module Deprecations
      extend Base

      module_function

      def install!(_app)
        subscribe("deprecation.rails") do |event|
          exe = execution
          exe&.count(:deprecations)
          next unless recording?
          p = event.payload
          Nightrail.record(:deprecation,
            group: Record.group_hash(p[:gem_name], p[:message].to_s[0, 120]),
            message: p[:message].to_s[0, 2048],
            gem_name: p[:gem_name].to_s,
            horizon: p[:deprecation_horizon].to_s,
            source: Array(p[:callstack]).find { |f| f.to_s.start_with?(Backtrace.app_root) }&.to_s&.delete_prefix(Backtrace.app_root))
        end
      end
    end
  end
end
