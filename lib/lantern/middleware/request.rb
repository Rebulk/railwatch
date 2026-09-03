# frozen_string_literal: true

module Lantern
  module Middleware
    # Outermost Rack middleware. Opens the request execution, times the
    # lifecycle stages, catches anything that escapes the stack as an
    # unhandled exception, and emits the request record at the end.
    class Request
      IGNORED_PATHS = %w[/up /lantern/beacon].freeze
      # Env keys repeat request after request (same client/proxy headers), so
      # the Rack key -> "Header-Name" conversion is cached instead of
      # split/map/capitalize/join-ing on every request.
      HEADER_NAME_CACHE_LIMIT = 512

      def initialize(app)
        @app = app
        @header_name_cache = {}
        @header_name_mutex = Mutex.new
      end

      def call(env)
        return @app.call(env) unless Lantern.enabled? || IGNORED_PATHS.include?(env["PATH_INFO"])

        exe = Lantern.start_execution(source: :request, sample_kind: :requests,
                                      trace_id: env["HTTP_TRACEPARENT"]&.split("-")&.at(1))
        exe.enter_stage(:middleware_before)
        env["lantern.execution"] = exe
        status = headers = body = nil
        begin
          status, headers, body = @app.call(env)
        rescue Exception => e # rubocop:disable Lint/RescueException
          Subscribers::Exceptions.capture(e, handled: false, severity: :error, source: "lantern.middleware")
          raise
        ensure
          exe.enter_stage(:middleware_after) unless exe.stage == :middleware_after
          finish(env, exe, status, headers)
        end
        [ status, headers, body ]
      end

      private

      def finish(env, exe, status, headers)
        exe.finish_stages
        Lantern.finish_execution(:request, **parent_fields(env, exe, status, headers))
      rescue StandardError => e
        Lantern.debug { "request finish failed: #{e.class}: #{e.message}" }
        Lantern.finish_execution
      end

      def parent_fields(env, exe, status, headers)
        req = ActionDispatch::Request.new(env)
        route = env["lantern.route"] || {}
        pattern = route[:pattern] || (req.respond_to?(:route_uri_pattern) ? (req.route_uri_pattern rescue nil) : nil) || "unmatched"
        controller = route[:controller]
        action = route[:action]
        method = req.request_method
        exe.preview ||= "#{method} #{pattern}"
        exe.user_id ||= Subscribers::Users.resolve_id(env)

        inertia = inertia_fields(env, headers)
        payload = Lantern.config.capture_request_payload && exe.counters[:exceptions].positive? ? Lantern.redactor.params(req.filtered_parameters.except("controller", "action")) : nil

        {
          group: Record.group_hash(method, pattern),
          method: method,
          url: req.original_url.to_s[0, 2048],
          path: req.path,
          route: pattern,
          route_methods: [ route[:verb] ].compact,
          route_domain: req.host,
          controller: controller,
          action: action,
          format: (req.format&.symbol rescue nil).to_s,
          ip: req.remote_ip,
          status_code: status.to_i,
          request_size: req.content_length.to_i,
          response_size: headers && (headers["Content-Length"] || headers["content-length"]).to_i,
          view_runtime: env["lantern.view_runtime"],
          db_runtime: env["lantern.db_runtime"],
          redirect_to: env["lantern.redirect_to"],
          halted_callback: env["lantern.halted_callback"],
          unpermitted_parameters: env["lantern.unpermitted_parameters"],
          rate_limited: env["lantern.rate_limited"],
          inertia: inertia,
          headers: request_headers(env),
          payload: payload,
          user_agent: req.user_agent.to_s[0, 256],
          files: env["lantern.files"] || uploaded_files(req.params)
        }
      end

      def inertia_fields(env, headers)
        # The X-Inertia response header is only set on the XHR-follow-up
        # branch; a full-page (SSR or not) Inertia render never sets it, so
        # the presence of the component env var (set on every Inertia
        # render) also has to open this gate or SSR timing is silently lost.
        return nil unless env["HTTP_X_INERTIA"] == "true" || (headers && (headers["X-Inertia"] || headers["x-inertia"])) || env["lantern.inertia_component"]

        {
          component: env["lantern.inertia_component"],
          version: env["HTTP_X_INERTIA_VERSION"],
          partial_component: env["HTTP_X_INERTIA_PARTIAL_COMPONENT"],
          partial_only: env["HTTP_X_INERTIA_PARTIAL_DATA"],
          partial_except: env["HTTP_X_INERTIA_PARTIAL_EXCEPT"],
          props_bytes: env["lantern.inertia_props_bytes"],
          ssr_ms: env["lantern.inertia_ssr_ms"]
        }.compact
      end

      # Recursively pulls ActionDispatch::Http::UploadedFile metadata out of
      # request.params -- never its contents. Handles both a single file
      # field and array-of-files fields (e.g. `attachments[]`).
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
      end

      # Builds the (already redacted) header hash in one pass over env so the
      # redactor does not have to walk a second, intermediate hash.
      def request_headers(env)
        redactor = Lantern.redactor
        out = {}
        env.each_pair do |k, v|
          next unless k.start_with?("HTTP_") || k == "CONTENT_TYPE" || k == "CONTENT_LENGTH"
          name = header_name(k)
          out[name] = redactor.redact_header?(name) ? Redactor::FILTERED : v.to_s[0, 512]
        end
        out
      end

      def header_name(key)
        cached = @header_name_cache[key]
        return cached if cached

        name = key.delete_prefix("HTTP_").split("_").map(&:capitalize).join("-")
        @header_name_mutex.synchronize do
          @header_name_cache.clear if @header_name_cache.size >= HEADER_NAME_CACHE_LIMIT
          @header_name_cache[key] = name
        end
        name
      end
    end
  end
end
