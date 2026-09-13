# frozen_string_literal: true

module Railwatch
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
      TRACEPARENT = /\A([0-9a-f]{2})-([0-9a-f]{32})-([0-9a-f]{16})-([0-9a-f]{2})(.*)\z/
      # Reverse proxies stamp the moment the request was accepted; the gap to
      # our own start is how long it waited for a worker. Anything beyond this
      # is clock skew between the proxy and this box, not a real wait.
      MAX_QUEUE_TIME = 60_000_000 # microseconds
      # Only a multipart request can carry an UploadedFile; same raw
      # CONTENT_TYPE test Subscribers::Requests uses before its params walk.
      MULTIPART = "multipart/form-data"
      NO_FILES = [].freeze

      # Returns [trace_id, parent_id, sampled] from an inbound traceparent,
      # or nil when the header is absent or malformed.
      def self.traceparent(value)
        match = value && TRACEPARENT.match(value)
        return nil unless match
        return nil if match[1] == "ff"
        # Version 00 has exactly 55 characters. Future versions may append
        # opaque fields, but W3C requires the byte after trace-flags to be a
        # dash; do not inspect or make assumptions about the fields beyond it.
        return nil if match[1] == "00" && !match[5].empty?
        return nil unless match[5].empty? || match[5].start_with?("-")
        return nil if match[2] == "0" * 32 || match[3] == "0" * 16

        [ match[2], match[3], match[4].to_i(16).odd? ]
      end

      def initialize(app)
        @app = app
        @header_name_cache = {}
        @header_name_mutex = Mutex.new
      end

      def call(env)
        return @app.call(env) unless Railwatch.enabled?
        return @app.call(env) if ignored_request?(env)

        trace_id, parent_id, upstream_sampled = self.class.traceparent(env["HTTP_TRACEPARENT"])
        exe = Railwatch.start_execution(source: :request, sample_kind: :requests,
                                      trace_id: trace_id, parent_id: parent_id)
        # The upstream service sampled this trace in, so keep our end of it
        # too -- otherwise the trace has a hole where this request should be.
        exe.keep! if upstream_sampled
        exe.enter_stage(:middleware_before)
        env["railwatch.execution"] = exe
        status = headers = body = nil
        begin
          status, headers, body = @app.call(env)
        rescue Exception => e # rubocop:disable Lint/RescueException
          Subscribers::Exceptions.capture(e, handled: false, severity: :error, source: "railwatch.middleware")
          raise
        ensure
          exe.enter_stage(:middleware_after) unless exe.stage == :middleware_after
          finish(env, exe, status, headers)
        end
        [ status, headers, body ]
      end

      private

      def ignored_request?(env)
        path = env["PATH_INFO"].to_s
        Railwatch.config.ignored_request_paths.any? do |pattern|
          pattern.is_a?(Regexp) ? pattern.match?(path) : pattern.to_s == path
        end || self_ingest_request?(env, path)
      end

      # Railwatch Cloud monitors itself. Its reporter therefore POSTs back into
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
        return false unless env["HTTP_AUTHORIZATION"] == "Bearer #{Railwatch.config.token}"

        endpoint = URI.join(Railwatch.config.ingest_url, "/ingest")
        return false unless path == endpoint.path

        request = Rack::Request.new(env)
        request.scheme.casecmp?(endpoint.scheme) &&
          request.hostname.casecmp?(endpoint.host) &&
          request.port == endpoint.port
      rescue StandardError
        false
      end

      def finish(env, exe, status, headers)
        exe.finish_stages
        # Resolved here, once, for both the request record and the session
        # key below (the start_processing subscriber ran before the app's
        # before_actions, so it usually found no user yet).
        exe.user_id ||= Subscribers::Users.resolve_id(env)
        # The block is only called when the request record is going to ship;
        # a head-sampled-out request nothing rescued skips the
        # ActionDispatch::Request and the header walk entirely.
        Railwatch.finish_execution(:request) { parent_fields(env, exe, status, headers) }
        # A request with no user and no session cookie has no session, and
        # Sessions.touch returns without writing anything.
        Sessions.touch(exe, env, status) if Railwatch.config.track_sessions
      rescue StandardError => e
        Railwatch.debug { "request finish failed: #{e.class}: #{e.message}" }
        Railwatch.finish_execution
      end

      def parent_fields(env, exe, status, headers)
        req = ActionDispatch::Request.new(env)
        route = env["railwatch.route"] || {}
        pattern = route[:pattern] || (req.respond_to?(:route_uri_pattern) ? (req.route_uri_pattern rescue nil) : nil) || "unmatched"
        controller = route[:controller]
        action = route[:action]
        method = req.request_method
        exe.preview ||= "#{method} #{pattern}"

        inertia = inertia_fields(env, headers)
        payload = Railwatch.config.capture_request_payload && exe.counters[:exceptions].positive? ? Railwatch.redactor.params(req.filtered_parameters.except("controller", "action")) : nil

        {
          group: Record.group_hash(method, pattern),
          method: method,
          url: Record.url_without_sensitive_components(req.original_url, limit: 2048),
          path: req.path,
          route: pattern,
          route_methods: [ route[:verb] ].compact,
          route_domain: req.host,
          controller: controller,
          action: action,
          format: request_format(req, env),
          ip: req.remote_ip,
          status_code: status.to_i,
          request_size: req.content_length.to_i,
          response_size: headers && (headers["Content-Length"] || headers["content-length"]).to_i,
          view_runtime: env["railwatch.view_runtime"],
          db_runtime: env["railwatch.db_runtime"],
          redirect_to: env["railwatch.redirect_to"],
          halted_callback: env["railwatch.halted_callback"],
          unpermitted_parameters: env["railwatch.unpermitted_parameters"],
          rate_limited: env["railwatch.rate_limited"],
          inertia: inertia,
          headers: request_headers(env),
          payload: payload,
          queue_time: queue_time(env, exe),
          user_agent: req.user_agent.to_s[0, 256],
          files: env["railwatch.files"] || uploaded_files_fallback(req, env)
        }
      end

      # Rack parses the request body the first time anything asks it for
      # params, and both of the reads below ask -- `uploaded_files` walks
      # `request.params`, and ActionDispatch::Request#format goes through
      # `parameters[:format]`.
      #
      # Once a controller has run, that parse has already happened and its
      # result is memoized on env, so both reads are free (and the files were
      # captured back in Subscribers::Requests, before Rack::TempfileReaper
      # unlinked the tempfiles). When no controller ran -- a routing 404, a
      # rack-attack block, a middleware that rejected the request -- doing it
      # here would make Railwatch the only component that ever reads that body,
      # at teardown, after the response has been decided. A streaming upload,
      # or simply megabytes we would immediately throw away.
      #
      # So the fallback is narrow: multipart only, because nothing else can
      # contain a file, and no format symbol is worth parsing a body for.
      def uploaded_files_fallback(req, env)
        return NO_FILES unless multipart?(env)

        uploaded_files(req.params)
      end

      def request_format(req, env)
        return "" unless env.key?("action_dispatch.request.formats") || multipart?(env)

        (req.format&.symbol rescue nil).to_s
      end

      def multipart?(env)
        content_type = env["CONTENT_TYPE"]
        !content_type.nil? && content_type.start_with?(MULTIPART)
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
        return nil unless env["HTTP_X_INERTIA"] == "true" || (headers && (headers["X-Inertia"] || headers["x-inertia"])) || env["railwatch.inertia_component"]

        {
          component: env["railwatch.inertia_component"],
          version: env["HTTP_X_INERTIA_VERSION"],
          partial_component: env["HTTP_X_INERTIA_PARTIAL_COMPONENT"],
          partial_only: env["HTTP_X_INERTIA_PARTIAL_DATA"],
          partial_except: env["HTTP_X_INERTIA_PARTIAL_EXCEPT"],
          props_bytes: env["railwatch.inertia_props_bytes"],
          ssr_ms: env["railwatch.inertia_ssr_ms"]
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
        redactor = Railwatch.redactor
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
