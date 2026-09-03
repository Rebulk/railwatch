# frozen_string_literal: true

module Lantern
  module Subscribers
    # Controller lifecycle. The Rack middleware owns the request record; this
    # subscriber fills in route, stage boundaries, and the extras Rails
    # exposes (redirects, halted callbacks, unpermitted params, rate limits).
    module Requests
      extend Base

      module_function

      def install!(_app)
        subscribe("start_processing.action_controller") do |event|
          exe = execution or next
          p = event.payload
          exe.enter_stage(:action)
          env = p[:request]&.env
          next unless env
          env["lantern.route"] = { pattern: route_pattern(p[:request]), controller: p[:controller].to_s.delete_suffix("Controller").underscore, action: p[:action] }
          exe.preview = "#{p[:controller]}##{p[:action]}"
        end

        subscribe("process_action.action_controller") do |event|
          exe = execution or next
          p = event.payload
          env = p[:request]&.env or next
          env["lantern.view_runtime"] = p[:view_runtime]&.round(2)
          env["lantern.db_runtime"] = p[:db_runtime]&.round(2)
          exe.enter_stage(:middleware_after)
          resp = p[:response]
          if resp && env["HTTP_X_INERTIA"] == "true"
            env["lantern.inertia_props_bytes"] = resp.body.bytesize rescue nil
          end
        end

        subscribe("redirect_to.action_controller") do |event|
          env = event.payload[:request]&.env or next
          env["lantern.redirect_to"] = event.payload[:location].to_s[0, 512]
        end

        subscribe("halted_callback.action_controller") do |event|
          exe = execution or next
          ActiveSupport::ExecutionContext.to_h[:controller]&.request&.env&.[]=("lantern.halted_callback", event.payload[:filter].to_s)
        end

        subscribe("unpermitted_parameters.action_controller") do |event|
          env = event.payload.dig(:context, :request)&.env or next
          env["lantern.unpermitted_parameters"] = Array(event.payload[:keys]).map(&:to_s)
        end

        subscribe("rate_limit.action_controller") do |event|
          env = event.payload[:request]&.env or next
          env["lantern.rate_limited"] = { name: event.payload[:name].to_s, count: event.payload[:count], to: event.payload[:to] }
        end

        subscribe("render_template.action_view") do |_event|
          exe = execution or next
          exe.enter_stage(:render) if exe.stage == :action
        end
      end

      def route_pattern(request)
        request.route_uri_pattern
      rescue StandardError
        nil
      end
    end
  end
end
