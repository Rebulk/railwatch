# frozen_string_literal: true

module Lantern
  module Middleware
    # Outermost Rack middleware. Opens the request execution, times the
    # lifecycle stages, catches anything that escapes the stack as an
    # unhandled exception, and emits the request record at the end.
    class Request
      # Env keys repeat request after request (same client/proxy headers), so
      # the Rack key -> "Header-Name" conversion is cached instead of
      # split/map/capitalize/join-ing on every request.
      HEADER_NAME_CACHE_LIMIT = 512
      # W3C trace context: version-trace_id-parent_id-flags, all lower-case hex.
      TRACEPARENT = /\A([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})\z/
      # Reverse proxies stamp the moment the request was accepted; the gap to
      # our own start is how long it waited for a worker. Anything beyond this
      # is clock skew between the proxy and this box, not a real wait.
      MAX_QUEUE_TIME = 60_000_000 # microseconds

      # Returns [trace_id, parent_id, sampled] from an inbound traceparent,
      # or nil when the header is absent or malformed.
      def self.traceparent(value)
        match = value && TRACEPARENT.match(value)
        return nil unless match

        [ match[2], match[3], match[4].to_i(16).odd? ]
      end

      def initialize(app)
        @app = app
        @header_name_cache = {}
        @header_name_mutex = Mutex.new
      end

      def call(env)
        return @app.call(env) unless Lantern.enabled?
        return @app.call(env) if ignored_request?(env)

        trace_id, parent_id, upstream_sampled = self.class.traceparent(env["HTTP_TRACEPARENT"])
        exe = Lantern.start_execution(source: :request, sample_kind: :requests,
                                      trace_id: trace_id, parent_id: parent_id)
        # The upstream service sampled this trace in, so keep our end of it
        # too -- otherwise the trace has a hole where this request should be.
        exe.keep! if upstream_sampled
        exe.enter_stage(:middleware_before)
        env["lantern.execution"] = exe
        status = headers = body = nil
        app_failed = false
        begin
          status, headers, body = @app.call(env)
        rescue Exception => e # rubocop:disable Lint/RescueException
          app_failed = true
          Subscribers::Exceptions.capture(e, handled: false, severity: :error, source: "lantern.middleware")
          raise
        ensure
          exe.enter_stage(:middleware_after) unless exe.stage == :middleware_after
          finish(env, exe, status, headers, app_failed: app_failed)
        end
        [ status, headers, body ]
      end

      private

      def ignored_request?(env)
        path = env["PATH_INFO"].to_s
        Lantern.config.ignored_request_paths.any? do |pattern|
          pattern.is_a?(Regexp) ? pattern.match?(path) : pattern.to_s == path
        end || self_ingest_request?(env, path)
      end

      # Lantern Cloud monitors itself. Its reporter therefore POSTs back into
      # the same Rails process, and recording that POST would put another
      # request record in the reporter forever: flush -> /ingest -> flush.
      #
      # Path alone is not enough: a customer application can own an unrelated
      # /ingest route. This exemption needs the exact transport method, bearer
      # token and public origin. Rack::Request normalizes Forwarded and
      # X-Forwarded-* headers (including a non-default forwarded port), so the
      # comparison still works behind a TLS-terminating reverse proxy without
      # confusing the proxy's internal host with the public ingest origin.
      def self_ingest_request?(env, path)
        return false unless env["REQUEST_METHOD"] == "POST"
        return false unless env["HTTP_AUTHORIZATION"] == "Bearer #{Lantern.config.token}"

        endpoint = URI.join(Lantern.config.ingest_url, "/ingest")
        return false unless path == endpoint.path

        request = Rack::Request.new(env)
        request.scheme.casecmp?(endpoint.scheme) &&
          request.hostname.casecmp?(endpoint.host) &&
          request.port == endpoint.port
      rescue StandardError
        false
      end

      def finish(env, exe, status, headers, app_failed:)
        exe.finish_stages
        Lantern.finish_execution(:request, **parent_fields(env, exe, status, headers, app_failed: app_failed))
        # After the parent, which is where exe.user_id is resolved: a request
        # with no user and no session cookie has no session, and Sessions.touch
        # returns without writing anything.
        Sessions.touch(exe, env, status) if Lantern.config.track_sessions
      rescue StandardError => e
        Lantern.debug { "request finish failed: #{e.class}: #{e.message}" }
        Lantern.finish_execution
      end

      def parent_fields(env, exe, status, headers, app_failed:)
        req = ActionDispatch::Request.new(env)
        route = env["lantern.route"] || {}
        pattern = route[:pattern] || (req.respond_to?(:route_uri_pattern) ? (req.route_uri_pattern rescue nil) : nil) || "unmatched"
        controller = route[:controller]
        action = route[:action]
        method = req.request_method
        exe.preview ||= "#{method} #{pattern}"
        exe.user_id ||= Subscribers::Users.resolve_id(env)

        inertia = inertia_fields(env, headers)
        payload = request_payload(env, req, exe, app_failed: app_failed)

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
          format: request_format(env, req, app_failed: app_failed),
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
          queue_time: queue_time(env, exe),
          user_agent: req.user_agent.to_s[0, 256],
          files: request_files(env, req, app_failed: app_failed)
        }
      end

      # A rejected JSON or urlencoded request may never otherwise need its
      # body parsed. Only multipart forms can contain UploadedFile objects,
      # so do not make Lantern the component that consumes a hostile body
      # while the outer middleware is finishing the request.
      def request_files(env, request, app_failed:)
        return env["lantern.files"] if env.key?("lantern.files")
        # If the inner stack raised, Rack::TempfileReaper has already run its
        # exception cleanup before control reaches this outer ensure. Parsing
        # now could create upload tempfiles that nobody will close.
        return [] if app_failed
        return [] unless RequestMediaType.multipart_form_data?(env["CONTENT_TYPE"])

        uploaded_files(request.params)
      rescue StandardError => e
        Lantern.debug { "request upload inspection failed: #{e.class}: #{e.message}" }
        []
      end

      # Payload capture is explicitly opt-in and exception-only, so it may
      # parse a request body. A broken or hostile Rack input must only omit
      # this optional field, never discard the request's parent record.
      def request_payload(env, request, exe, app_failed:)
        return nil unless Lantern.config.capture_request_payload && exe.counters[:exceptions].positive?
        return nil if app_failed && !env.key?("action_dispatch.request.request_parameters")

        Lantern.redactor.params(request.filtered_parameters.except("controller", "action"))
      rescue StandardError => e
        Lantern.debug { "request payload inspection failed: #{e.class}: #{e.message}" }
        nil
      end

      # ActionDispatch derives multipart formats through `parameters`, which
      # parses the body. During exception unwind only use a value Rails has
      # already cached; Rack's tempfile exception cleanup has already run.
      def request_format(env, request, app_failed:)
        return "" if app_failed && !env.key?("action_dispatch.request.formats")

        request.format&.symbol.to_s
      rescue StandardError
        ""
      end

      # Microseconds this request waited in the proxy/web-server queue before
      # the execution started, from X-Request-Start (nginx, Heroku, HAProxy)
      # or X-Queue-Start. nil when absent, unparseable, or implausible.
      def queue_time(env, exe)
        raw = env["HTTP_X_REQUEST_START"] || env["HTTP_X_QUEUE_START"]
        started = raw && request_start_seconds(raw)
        return nil unless started

        micros = ((exe.started_at - started) * 1_000_000).round
        return nil if micros > MAX_QUEUE_TIME

        # A proxy clock running slightly ahead reads as a negative wait.
        micros.negative? ? 0 : micros
      end

      # "t=1700000000.123" (seconds), "t=1700000000123" (ms),
      # "t=1700000000123456" (microseconds), or the same values bare. A proxy
      # chain can collapse several into one comma-separated header; the first
      # is the outermost. Unit is decided by magnitude, like Sentry's
      # extract_queue_time.
      def request_start_seconds(value)
        raw = value.to_s.split(",").first.to_s.strip.delete_prefix("t=").strip
        return nil unless /\A\d+(?:\.\d+)?\z/.match?(raw)

        seconds = raw.to_f
        if seconds > 10_000_000_000_000 then seconds / 1_000_000
        elsif seconds > 10_000_000_000 then seconds / 1_000
        else seconds
        end
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
