# frozen_string_literal: true

module Lantern
  module Middleware
    # Outermost Rack middleware. Opens the request execution, times the
    # lifecycle stages, catches anything that escapes the stack as an
    # unhandled exception, and emits the request record at the end.
    class Request
      EXECUTOR_CALL_SOURCE = ActionDispatch::Executor.instance_method(:call).source_location&.first
      private_constant :EXECUTOR_CALL_SOURCE

      # Keeps a Rack response body attached to the request execution until the
      # server has consumed it. Rack applications return the body before an
      # Enumerator (or another streaming body) does its work, often on a
      # different thread, so finalizing in #call loses everything emitted by
      # #each and reports only the time needed to construct the response.
      #
      # Completion normally owns the wrapped body's close: this makes normal
      # enumeration, a downstream disconnect, and an explicit close all take
      # the same exactly-once path. The Rack #to_ary protocol is the exception:
      # a coercible body owns its close, so completion only finalizes around it.
      class ResponseBody
        def initialize(body, middleware, env, execution, status, headers, context_snapshot)
          @body = body
          @middleware = middleware
          @env = env
          @execution = execution
          @status = status
          @headers = headers
          @context_snapshot = context_snapshot
          @origin_thread = Thread.current
          @origin_context = ActiveSupport::IsolatedExecutionState.context
          @completion_mutex = Mutex.new
          @active_operations = 0
          @close_started = false
          @close_finished = false
          @finalization_claimed = false
          @deferred_profile_stopped = false
          @preserving = nil
          stop_deferred_profile if ActiveSupport::IsolatedExecutionState.isolation_level == :fiber
        end

        def close
          complete
        end

        def closed?
          @completion_mutex.synchronize { @close_started }
        end

        def respond_to_missing?(method_name, include_all = false)
          method_name != :to_str && (@body.respond_to?(method_name, include_all) || super)
        end

        def method_missing(method_name, *args, &block)
          return super if method_name == :to_str
          return consume_to_ary(*args, &block) if method_name == :to_ary
          return observe_to_path(*args, &block) if method_name == :to_path

          @body.__send__(method_name, *args, &block)
        end
        ruby2_keywords(:method_missing) if respond_to?(:ruby2_keywords, true) # :nocov:

        private

        def consume(capture_error: nil, close_body: true)
          begin_operation
          error = nil
          with_request_state do
            begin
              yield
            rescue Exception => e # rubocop:disable Lint/RescueException
              error = e
              capture(e) unless capture_error && !capture_error.call(e)
              raise
            ensure
              complete(preserving: error, consumption_finished: true, close_body: close_body)
            end
          end
        end

        def begin_operation
          @completion_mutex.synchronize do
            raise IOError, "closed response body" if @close_started

            @active_operations += 1
          end
        end

        def consume_to_ary(*args, &block)
          # Rack requires a body that has both #to_ary and #close to close
          # itself from #to_ary. Do not close it a second time here; the outer
          # wrapper still marks itself closed and finalizes the request.
          Context.with(close_context_snapshot) do
            consume(close_body: false) { @body.__send__(:to_ary, *args, &block) }
          end
        end

        def observe_to_path(*args, &block)
          # Rack may use #to_path instead of #each to send a file efficiently,
          # but explicitly says it does not consume the body. Keep any lazy
          # application work and failures attached to the request without
          # closing it; the server still owns the eventual #close call.
          begin_operation
          error = nil
          with_request_state do
            begin
              @body.__send__(:to_path, *args, &block)
            rescue Exception => e # rubocop:disable Lint/RescueException
              error = e
              capture(e)
              raise
            ensure
              finish_observation(preserving: error)
            end
          end
        end

        def finish_observation(preserving:)
          should_finalize = @completion_mutex.synchronize do
            @active_operations -= 1
            @preserving ||= preserving
            claim_finalization if @close_finished
          end
          finalize if should_finalize
        end

        def consume_stream(stream)
          downstream_error = nil
          capture_error = ->(error) { !EnumerableResponseBody::IDENTICAL.bind_call(error, downstream_error) }
          proxy = DownstreamStream.new(stream, ->(error) { downstream_error = error })
          consume(capture_error: capture_error) { yield proxy }
        end

        def complete(preserving: nil, consumption_finished: false, close_body: true)
          close_owner = false
          should_finalize = false
          @completion_mutex.synchronize do
            @active_operations -= 1 if consumption_finished
            @preserving ||= preserving
            unless @close_started
              @close_started = true
              close_owner = true
            end
            should_finalize = claim_finalization if @close_finished
          end

          close_error = nil
          if close_owner
            with_request_state do
              close_snapshot = close_context_snapshot(refresh: close_body)
              Context.with(close_snapshot) do
                begin
                  @body.close if close_body && @body.respond_to?(:close)
                rescue Exception => e # rubocop:disable Lint/RescueException
                  close_error = e
                  Context.with(close_snapshot) { capture(e) } unless preserving || downstream_disconnect?(e)
                ensure
                  @completion_mutex.synchronize do
                    @preserving ||= close_error
                    @close_finished = true
                    should_finalize = claim_finalization
                  end
                end
              end
            end
          end

          finalize if should_finalize
          raise close_error if close_error && !preserving
        end

        def claim_finalization
          return false if @finalization_claimed || !@close_finished || @active_operations.positive?

          @finalization_claimed = true
        end

        def finalize
          # Finalization can be delayed after #close while another thread is
          # still enumerating or resolving #to_path. Serialize only now, after
          # the last active operation has finished, so its context is present.
          context = Context.with(close_context_snapshot(refresh: false)) { Context.serialized }
          with_request_state do
            @middleware.__send__(:finish, @env, @execution, @status, @headers,
                                 preserving: @preserving, context: context)
          end
        end

        def with_request_state(&block)
          stop_deferred_profile unless Thread.current.equal?(@origin_thread)
          Current.with(@execution) do
            if ActiveSupport::IsolatedExecutionState.context.equal?(@origin_context)
              block.call
            else
              Context.with(@context_snapshot, &block)
            end
          end
        end

        def stop_deferred_profile
          should_stop = @completion_mutex.synchronize do
            next false if @deferred_profile_stopped

            @deferred_profile_stopped = true
          end
          Lantern.discard_execution(@execution) if should_stop
        end

        def close_context_snapshot(refresh: true)
          write_through = ActiveSupport::IsolatedExecutionState.context.equal?(@origin_context)
          if refresh && write_through && !Context.override
            current = Context.current
            @context_snapshot.mutex.synchronize { @context_snapshot.values.merge!(current) }
          end
          Context::Snapshot.new(values: @context_snapshot.values, tenant: @context_snapshot.tenant,
                                write_through: write_through, mutex: @context_snapshot.mutex)
        end

        def downstream_disconnect?(error)
          Errno::EPIPE === error || Errno::ECONNRESET === error
        end

        def capture(error)
          @middleware.__send__(:capture_exception, @execution, error)
        end
      end

      # Rack 3 distinguishes enumerable bodies from call-style streaming
      # bodies. The wrapper must preserve that distinction: if it advertised
      # #each for a call-only body, a conforming server would choose #each and
      # fail before the stream was written.
      class EnumerableResponseBody < ResponseBody
        IDENTICAL = BasicObject.instance_method(:equal?)

        def each
          return enum_for(:each) unless block_given?

          downstream_error = nil
          capture_error = ->(error) { !IDENTICAL.bind_call(error, downstream_error) }
          consume(capture_error: capture_error) do
            @body.each do |chunk|
              begin
                yield chunk
              rescue Exception => e # rubocop:disable Lint/RescueException
                downstream_error = e
                raise
              end
            end
          end
        end
      end

      class StreamingResponseBody < ResponseBody
        def call(stream)
          consume_stream(stream) { |proxy| @body.call(proxy) }
        end
      end

      # Identifies the exact exception raised by the downstream connection.
      # Streaming bodies write to an IO rather than yielding chunks, so there
      # is otherwise no boundary that distinguishes an application failure
      # from an EPIPE/IOError raised while sending to a disconnected client.
      class DownstreamStream
        def initialize(stream, on_error)
          @stream = stream
          @on_error = on_error
        end

        def respond_to_missing?(method_name, include_all = false)
          @stream.respond_to?(method_name, include_all) || super
        end

        def method_missing(method_name, *args, &block)
          result = @stream.__send__(method_name, *args, &block)
          # IO#<< returns the receiver. Keep chained writes on this proxy so
          # a later chunk's disconnect is identified at the same boundary.
          result.equal?(@stream) && method_name == :<< ? self : result
        rescue Exception => e # rubocop:disable Lint/RescueException
          @on_error.call(e)
          raise
        end
        ruby2_keywords(:method_missing) if respond_to?(:ruby2_keywords, true) # :nocov:
      end

      class HijackCallback
        def initialize(callback, lifecycle)
          @callback = callback
          @lifecycle = lifecycle
        end

        def call(stream, *args, &block)
          @lifecycle.__send__(:consume_stream, stream) { |proxy| @callback.call(proxy, *args, &block) }
        end
        ruby2_keywords(:call) if respond_to?(:ruby2_keywords, true) # :nocov:
      end

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
        application_error = nil
        begin
          begin
            status, headers, body = @app.call(env)
          rescue Exception => e # rubocop:disable Lint/RescueException
            application_error = e
            capture_exception(exe, e)
            raise
          ensure
            if application_error
              begin
                enter_middleware_after(exe, preserving: application_error)
              ensure
                finish(env, exe, status, headers, preserving: application_error)
              end
            end
          end

          begin
            enter_middleware_after(exe)
          rescue Exception => setup_error # rubocop:disable Lint/RescueException
            finish(env, exe, status, headers, preserving: setup_error)
            raise
          end

          begin
            if (hijack = headers && headers["rack.hijack"])
              context_snapshot = streaming_context(env, exe)
              lifecycle = response_body(body, env, exe, status, headers, context_snapshot)
              headers = headers.dup
              headers["rack.hijack"] = HijackCallback.new(hijack, lifecycle)
              # Rack servers ignore the body after a partial hijack, but they
              # must still close it. Return the shared lifecycle wrapper so a
              # disconnect while sending headers (before callback invocation)
              # cannot strand the request execution or process-global profile.
              body = lifecycle
            # Keep the ordinary, already-materialized Rails response on the
            # pre-streaming path. ActionDispatch::Executor normally wraps its
            # RackBody in Rack::BodyProxy, so eager_response_body? looks
            # through only proxies created by ActionDispatch::Executor. A
            # generic BodyProxy may run application work from its close
            # callback and must remain inside the request lifecycle.
            elsif eager_response_body?(body)
              finish(env, exe, status, headers, preserving: nil)
            else
              context_snapshot = streaming_context(env, exe)
              body = response_body(body, env, exe, status, headers, context_snapshot)
            end
          rescue Exception => setup_error # rubocop:disable Lint/RescueException
            finish(env, exe, status, headers, preserving: setup_error)
            raise
          end
        ensure
          # #each may run later or on another thread. Neither this request nor
          # a nested execution abandoned by the app may remain Current on the
          # server thread after the Rack response has been returned.
          Current.execution = exe.parent_execution
        end
        [ status, headers, body ]
      end

      private

      def eager_response_body?(body)
        return true if body.instance_of?(Array)

        candidate = body
        while rails_executor_body_proxy?(candidate)
          candidate = candidate.instance_variable_get(:@body)
        end
        return true if candidate.instance_of?(Array)
        return false unless candidate.instance_of?(ActionDispatch::Response::RackBody)

        stream = candidate.response.stream
        return false unless stream.instance_of?(ActionDispatch::Response::Buffer)

        stream.instance_variable_get(:@buf).instance_of?(Array) ||
          stream.instance_variable_get(:@str_body).instance_of?(String)
      end

      def rails_executor_body_proxy?(body)
        return false unless body.instance_of?(Rack::BodyProxy)

        callback = body.instance_variable_get(:@block)
        callback.instance_of?(Proc) &&
          callback.source_location&.first == EXECUTOR_CALL_SOURCE
      end

      def streaming_context(env, exe)
        # Resolve Current.user and retain Lantern.context and tenant while
        # Rails' request executor is still active. Its inner body proxy clears
        # both when it closes, which is before our outer proxy emits the parent
        # request record.
        exe.user_id ||= Subscribers::Users.resolve_id(env)
        Context.snapshot
      end

      def response_body(body, env, exe, status, headers, context_snapshot)
        wrapper = body.respond_to?(:each) ? EnumerableResponseBody : StreamingResponseBody
        wrapper.new(body, self, env, exe, status, headers, context_snapshot)
      end

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

      def finish(env, exe, status, headers, preserving:, context: nil)
        failure = nil
        # Application code can open an execution and fail to close it. Request
        # finalization must still describe and close the execution this
        # middleware opened, never whichever execution happens to be current.
        Current.execution = exe
        exe.finish_stages
        fields = parent_fields(env, exe, status, headers)
        fields[:context] = context if context
        Current.execution = exe
        Lantern.finish_execution(:request, **fields)
        # After the parent, which is where exe.user_id is resolved: a request
        # with no user and no session cookie has no session, and Sessions.touch
        # returns without writing anything.
        Sessions.touch(exe, env, status) if Lantern.config.track_sessions
      rescue Exception => e # rubocop:disable Lint/RescueException
        failure = prefer_fatal(e, debug_failure("request finish failed", e))
      ensure
        begin
          Lantern.discard_execution(exe)
        rescue Exception => cleanup_error # rubocop:disable Lint/RescueException
          cleanup_error = prefer_fatal(cleanup_error, debug_failure("request execution cleanup failed", cleanup_error))
          failure = prefer_fatal(failure, cleanup_error)
        ensure
          Current.execution = exe.parent_execution
        end
        raise failure if fatal_exception?(failure) && !preserving
      end

      def enter_middleware_after(exe, preserving: nil)
        exe.enter_stage(:middleware_after) unless exe.stage == :middleware_after
      rescue Exception => stage_error # rubocop:disable Lint/RescueException
        debug_error = debug_failure("request stage cleanup failed", stage_error)
        stage_error = prefer_fatal(stage_error, debug_error)
        raise stage_error if fatal_exception?(stage_error) && !preserving
      end

      def capture_exception(exe, error)
        # The Rack app may have left a nested execution current before it
        # raised. Attribute the exception to the request regardless, and do
        # not let any telemetry failure replace the application's exception.
        Current.execution = exe
        Subscribers::Exceptions.capture(error, handled: false, severity: :error, source: "lantern.middleware")
      rescue Exception => capture_error # rubocop:disable Lint/RescueException
        debug_failure("request exception capture failed", capture_error)
      ensure
        Current.execution = exe
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
        payload, payload_truncated = request_payload(env, exe)

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
          format: request_format(env),
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
          payload_truncated: payload_truncated || nil,
          queue_time: queue_time(env, exe),
          user_agent: req.user_agent.to_s[0, 256],
          files: request_files(env)
        }
      end

      # Request teardown must never be the component that parses a body. The
      # controller subscriber captures normal Rails uploads while their
      # tempfiles are live; Rack endpoints and middleware can still contribute
      # metadata when they populated ActionDispatch's parameter cache first.
      def request_files(env)
        return UploadedFiles.normalize(env["lantern.files"]) if env.key?("lantern.files")
        return [] unless RequestMediaType.multipart_form_data?(env["CONTENT_TYPE"])

        parameters = env["action_dispatch.request.parameters"] ||
                     env["action_dispatch.request.request_parameters"] ||
                     env["rack.request.form_hash"]
        return [] unless parameters

        UploadedFiles.extract(parameters)
      rescue StandardError, SystemStackError => e
        Lantern.debug { "request upload inspection failed: #{e.class}: #{e.message}" }
        []
      end

      # Payload capture is explicitly opt-in and exception-only. It uses
      # ActionDispatch parameters only after an upstream component populated
      # one of its caches, so request teardown never initiates body parsing.
      def request_payload(env, exe)
        return [ nil, false ] unless Lantern.config.capture_request_payload && exe.counters[:exceptions].positive?

        cached = env["action_dispatch.request.parameters"] ||
                 env["action_dispatch.request.request_parameters"]
        return [ nil, false ] unless cached

        normalized = RequestPayload.normalize(cached)
        return [ nil, true ] if normalized.failed

        without_routing = normalized.value.except("controller", "action")
        filtered =
          if (filters = env["action_dispatch.parameter_filter"])
            ActiveSupport::ParameterFilter.new(Array(filters), mask: Redactor::FILTERED).filter(without_routing)
          else
            without_routing
          end
        filtered = Lantern.redactor.params(filtered)
        redaction_failed = !without_routing.empty? && filtered.empty?
        filtered = RequestPayload.normalize(filtered)
        [ filtered.failed ? nil : filtered.value, normalized.truncated || redaction_failed || filtered.truncated ]
      rescue StandardError, SystemStackError => e
        Lantern.debug { "request payload inspection failed: #{e.class}: #{e.message}" }
        [ nil, true ]
      end

      def debug_failure(message, error)
        Lantern.debug { "#{message}: #{error.class}: #{error.message}" }
      rescue Exception => debug_error # rubocop:disable Lint/RescueException
        debug_error
      end

      def fatal_exception?(error)
        SystemExit === error || SignalException === error || NoMemoryError === error
      end

      def prefer_fatal(current, candidate)
        return candidate unless current
        return candidate if !fatal_exception?(current) && fatal_exception?(candidate)

        current
      end

      # ActionDispatch derives formats through `parameters`, which can parse
      # the body. Controller processing normally populated this cache already;
      # an upstream rejection safely records no format instead of reading it.
      def request_format(env)
        env["action_dispatch.request.formats"]&.first&.symbol.to_s
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
