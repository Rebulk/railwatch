# frozen_string_literal: true

module Railwatch
  module Subscribers
    # Controller lifecycle. The Rack middleware owns the request record; this
    # subscriber fills in route, stage boundaries, and the extras Rails
    # exposes (redirects, halted callbacks, unpermitted params, rate limits).
    module Requests
      extend Base

      # Only a multipart request can carry an UploadedFile, so the (recursive)
      # params walk below is skipped entirely for the vast majority of
      # requests instead of running once per action.
      EMPTY_FILES = [].freeze
      # Redirects a browser follows with the original request method.
      PRESERVING_REDIRECTS = [ 307, 308 ].freeze

      module_function

      def install!(_app)
        subscribe("start_processing.action_controller") do |event|
          exe = execution or next
          p = event.payload
          exe.enter_stage(:action)
          env = p[:request]&.env
          next unless env
          env["railwatch.route"] = { pattern: route_pattern(p[:request]), controller: p[:controller].to_s.delete_suffix("Controller").underscore, action: p[:action], verb: p[:method] }
          exe.preview = "#{p[:controller]}##{p[:action]}"
          # Captured here, not in the closing middleware, because Rack's
          # TempfileReaper (nested inside us) has already closed and unlinked
          # upload tempfiles by the time the middleware unwinds.
          env["railwatch.files"] = env["CONTENT_TYPE"]&.start_with?("multipart/form-data") ? uploaded_files(p[:request].params) : EMPTY_FILES
        end

        subscribe("process_action.action_controller") do |event|
          exe = execution or next
          p = event.payload
          env = p[:request]&.env or next
          env["railwatch.view_runtime"] = p[:view_runtime]&.round(2)
          env["railwatch.db_runtime"] = p[:db_runtime]&.round(2)
          exe.enter_stage(:middleware_after)
          resp = p[:response]
          bytes = resp && inertia_props_bytes(resp)
          env["railwatch.inertia_props_bytes"] = bytes if bytes
        end

        subscribe("redirect_to.action_controller") do |event|
          env = event.payload[:request]&.env or next
          request = event.payload[:request]
          location = event.payload[:location].to_s
          # Cleaned whole, cut after; a redirect to a page of this app whose
          # route puts a token in the path (an edit-password link) has it
          # filtered. The browser follows a 307 or 308 with the request's
          # own method, and every other redirect with GET, so the target is
          # recognised the way it will be requested.
          method = PRESERVING_REDIRECTS.include?(event.payload[:status].to_i) ? request.request_method : "GET"
          clean = Record.url_without_sensitive_components(location, limit: location.length)
          env["railwatch.redirect_to"] = Railwatch.redactor.filter_url(clean, host: request.host, method: method)[0, 512]
        end

        subscribe("halted_callback.action_controller") do |event|
          exe = execution or next
          ActiveSupport::ExecutionContext.to_h[:controller]&.request&.env&.[]=("railwatch.halted_callback", event.payload[:filter].to_s)
        end

        subscribe("unpermitted_parameters.action_controller") do |event|
          env = event.payload.dig(:context, :request)&.env or next
          env["railwatch.unpermitted_parameters"] = Array(event.payload[:keys]).map(&:to_s)
        end

        subscribe("rate_limit.action_controller") do |event|
          env = event.payload[:request]&.env or next
          env["railwatch.rate_limited"] = { name: event.payload[:name].to_s, count: event.payload[:count], to: event.payload[:to] }
        end

        subscribe("render_template.action_view") do |_event|
          exe = execution or next
          exe.enter_stage(:render) if exe.stage == :action
        end
      end

      # The size of the page object Inertia rendered, for an Inertia visit
      # only. The request header X-Inertia is the client's and can be sent
      # to any action, and reading `body` is not free on every response: a
      # send_file body answers it with File.binread of the whole file, and
      # an ActionController::Live body by draining the chunks the server had
      # not sent yet, which cuts the client's stream short. So the response
      # must say it is one -- inertia_rails sets X-Inertia on the response
      # only on its JSON branch -- and its body must be the plain in-memory
      # buffer a `render json:` leaves (a Live buffer is a subclass).
      def inertia_props_bytes(response)
        return nil unless response.get_header("X-Inertia") == "true"
        return nil unless response.media_type == "application/json"
        return nil unless response.stream.instance_of?(ActionDispatch::Response::Buffer)

        response.body.bytesize
      rescue StandardError
        nil
      end

      def route_pattern(request)
        request.route_uri_pattern
      rescue StandardError
        nil
      end

      def uploaded_files(value, name = nil)
        case value
        when ActionDispatch::Http::UploadedFile
          [ { name: name, size: (value.tempfile.size rescue nil), content_type: value.content_type, error: nil } ]
        when Hash
          value.flat_map { |k, v| uploaded_files(v, k.to_s) }
        when Array
          value.flat_map { |v| uploaded_files(v, name) }
        else
          []
        end
      rescue StandardError
        []
      end
    end
  end
end
