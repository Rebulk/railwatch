# frozen_string_literal: true

module Railwatch
  # All settings, each overridable by a RAILWATCH_* env var. Mirrors the shape of
  # Laravel Nightwatch's config so the two products document the same knobs.
  class Configuration
    RECORD_TYPES = %i[queries cache_events mail broadcasts notifications outgoing_requests
                      storage_ops view_renders logs transactions deprecations sessions
                      llm_calls].freeze

    # Framework/vendor noise excluded by default so a fresh install isn't
    # dominated by Rails' own housekeeping. Both lists are opt-in to disable
    # via capture_default_vendor_commands / capture_default_vendor_cache_keys.
    DEFAULT_VENDOR_COMMANDS = %w[
      db:migrate db:schema:load db:schema:dump db:seed db:prepare
      assets:precompile assets:clobber tmp:cache:clear log:clear
    ].freeze

    DEFAULT_VENDOR_CACHE_KEYS = [
      /\Arack::attack/, /\Aflipper/, /\Asolid_cable/,
      /\Aactive_storage/, /\Amigration_/, /\Aschema_cache/
    ].freeze
    # The same list as one anchored alternation: one regex run per cache
    # event instead of six.
    DEFAULT_VENDOR_CACHE_KEY = Regexp.union(DEFAULT_VENDOR_CACHE_KEYS).freeze

    # Scratch roots. A deployed script ships in the image (under Rails.root,
    # or wherever the ops scripts live); a `.rb` file under one of these was
    # written by a human in a shell session, so `rails runner /tmp/probe.rb`
    # counts as interactive. Deliberately narrow -- two literal temp roots,
    # never "outside Rails.root" -- because a cron script going silent is the
    # failure this must not cause.
    DEFAULT_INTERACTIVE_RUNNER_PATHS = %w[/tmp/ /var/tmp/].freeze

    # Requests that are part of keeping the app observable rather than the
    # application itself. Monitoring these creates noise (/up) or wraps
    # Railwatch's own browser transport in another request execution (the
    # beacon). Apps can replace this list through RAILWATCH_IGNORED_REQUEST_PATHS
    # or append exact paths/regexps in their initializer.
    DEFAULT_IGNORED_REQUEST_PATHS = %w[/up /railwatch/beacon].freeze

    # Exceptions that are routine 4xx plumbing rather than application bugs.
    # The Rails-relevant subset of Sentry's own defaults
    # (Sentry::Configuration::IGNORE_DEFAULT + PUMA_IGNORE_DEFAULT and
    # Sentry::Rails::Configuration::IGNORE_DEFAULT), so a Sentry app migrating
    # to Railwatch sees the same signal-to-noise out of the box.
    DEFAULT_IGNORED_EXCEPTIONS = %w[
      SignalException
      ActionController::BadRequest
      ActionController::InvalidAuthenticityToken
      ActionController::RoutingError
      ActionController::UnknownFormat
      ActionController::UnknownHttpMethod
      ActionDispatch::Http::MimeNegotiation::InvalidType
      ActionDispatch::Http::Parameters::ParseError
      ActiveRecord::RecordNotFound
      Puma::HttpParserError
      Puma::HttpParserError501
      Rack::QueryParser::InvalidParameterError
      Rack::QueryParser::ParameterTypeError
    ].freeze

    # What the dashboard controllers inherit from unless the host names its
    # own. Also how `dashboard_gate` tells "they wired their own auth" from
    # "they left the default".
    DEFAULT_BASE_CONTROLLER = "ActionController::Base"

    attr_accessor :export_enabled, :export_policy, :export_url, :export_token, :export_max_bytes,
                  :export_max_deliveries, :export_max_age
    attr_accessor :enabled, :token, :ingest_url, :allow_http, :server, :environment, :transport,
                  :issue_prefix, :repository_url, :retention_days, :dashboard_user, :writer_socket,
                  :http_basic_auth_enabled, :http_basic_auth_user, :http_basic_auth_password, :base_controller_class,
                  :dashboard_open,
                  :sample, :log_level, :capture_request_payload,
                  :capture_exception_source, :capture_exception_locals, :redact_headers, :redact_params,
                  :buffer_size, :buffer_bytes, :execution_buffer_bytes, :batch_bytes,
                  :backpressure,
                  :flush_interval, :flush_threshold,
                  :connect_timeout, :timeout, :shutdown_timeout,
                  :slow_query_threshold_ms, :n_plus_one_threshold,
                  :max_view_renders_per_execution, :ignored_cache_key_prefixes,
                  :beacon_enabled, :beacon_rate_limit, :beacon_global_rate_limit, :beacon_allowed_origins,
                  :debug, :capture_default_vendor_commands,
                  :capture_default_vendor_cache_keys, :on_unrecoverable,
                  :capture_framework_events,
                  :tail_sample_slow_ms, :failure_context, :propagate_traces, :trace_propagation_hosts,
                  :health_interval, :capture_query_explain, :explain_threshold_ms,
                  :capture_sql_values,
                  :ignored_exceptions, :capture_rescued_exceptions,
                  :profile_sample, :profile_slow_ms, :profile_interval_us, :profiler,
                  :capture_job_arguments, :capture_job_retry_errors, :capture_response_body_on_error, :max_attachment_bytes,
                  :track_sessions, :session_flush_interval, :session_timeout,
                  :capture_console, :interactive_runner_paths, :ignored_request_paths,
                  :capture_llm_content

    attr_reader :deploy, :deploy_source, :detect_deploy, :user_resolver, :beacon_user_resolver,
                :fingerprint_resolver, :redactors, :rejectors, :before_ingest, :backpressure_high_water

    def initialize
      @enabled = env_bool("RAILWATCH_ENABLED", true)
      @token = ENV["RAILWATCH_TOKEN"]
      @transport = ENV.fetch("RAILWATCH_TRANSPORT", "http").to_sym
      # Embedded dashboard settings; ignored when transport is :http.
      @issue_prefix = ENV["RAILWATCH_ISSUE_PREFIX"]
      @repository_url = ENV["RAILWATCH_REPOSITORY_URL"]
      @retention_days = env_int("RAILWATCH_RETENTION_DAYS", 7)
      @dashboard_user = nil
      # Mirroring an embedded install's telemetry to a remote receiver. Off
      # unless asked for: an embedded install's promise is that nothing leaves
      # the machine, and a token being present is not consent.
      @export_enabled = env_bool("RAILWATCH_EXPORT_ENABLED", false)
      @export_policy = ENV.fetch("RAILWATCH_EXPORT_POLICY", "everything").to_sym
      @export_url = ENV["RAILWATCH_EXPORT_URL"]
      @export_token = ENV["RAILWATCH_EXPORT_TOKEN"]
      @export_max_bytes = env_int("RAILWATCH_EXPORT_MAX_BYTES", 256 * 1024 * 1024)
      @export_max_deliveries = env_int("RAILWATCH_EXPORT_MAX_DELIVERIES", 100_000)
      @export_max_age = env_int("RAILWATCH_EXPORT_MAX_AGE_SECONDS", 86_400)
      # Dashboard access, the way Mission Control Jobs does it: HTTP Basic
      # authentication is on and CLOSED by default. With no user and password
      # configured every dashboard request is 401, so an install that forgot
      # to set anything up is never a public page. Credentials come from
      # Rails credentials (railwatch.http_basic_auth_user/_password, written
      # by `bin/rails railwatch:authentication:configure`), from these env
      # vars, or by assignment here. A host with its own admin auth turns
      # Basic off and names a base controller, or wraps the mount in a
      # routes constraint.
      @http_basic_auth_enabled = env_bool("RAILWATCH_HTTP_BASIC_AUTH_ENABLED", true)
      @http_basic_auth_user = ENV["RAILWATCH_HTTP_BASIC_AUTH_USER"]
      @http_basic_auth_password = ENV["RAILWATCH_HTTP_BASIC_AUTH_PASSWORD"]
      # Only consulted when HTTP Basic is off: the host saying, in as many
      # words, "I accept that anyone who can reach this URL can read it".
      # A private network or a VPN is a real answer; this is how you say so,
      # and it is what silences the boot warning and opens the live channel.
      @dashboard_open = env_bool("RAILWATCH_DASHBOARD_OPEN", false)
      # The dashboard controllers inherit from this class, so a host's own
      # before_actions (require an admin, redirect to sign-in) run in front of
      # every page. Default is the engine's own base, which authenticates
      # nothing itself beyond HTTP Basic above.
      @base_controller_class = ENV.fetch("RAILWATCH_BASE_CONTROLLER_CLASS", DEFAULT_BASE_CONTROLLER)
      # Embedded mode's writer process (lib/railwatch/writer.rb): the Unix
      # socket the Puma workers hand their batches to. Relative paths are
      # under Rails.root. nil disables the writer and every process writes
      # its own batches, as before.
      @writer_socket = ENV.fetch("RAILWATCH_WRITER_SOCKET", "tmp/sockets/railwatch-writer.sock")
      @ingest_url = ENV.fetch("RAILWATCH_INGEST_URL", "https://railwatch.rebulk.com")
      @allow_http = env_bool("RAILWATCH_ALLOW_HTTP", false)
      @project_root = defined?(Rails) ? Rails.root : Dir.pwd
      @detect_deploy = env_bool("RAILWATCH_DETECT_DEPLOY", true)
      detect_release
      # Kamal names the container after the host plus a container id, so a
      # bare hostname changes on every deploy and never matches the host the
      # post-deploy hook registers as expected. KAMAL_HOST, which Kamal sets
      # in every container it starts, is that host.
      @server = ENV["RAILWATCH_SERVER"] || ENV["KAMAL_HOST"] || Socket.gethostname
      @environment = nil # resolved lazily from Rails.env
      @sample = {
        requests: env_float("RAILWATCH_REQUEST_SAMPLE_RATE", 1.0),
        jobs: env_float("RAILWATCH_JOB_SAMPLE_RATE", 1.0),
        commands: env_float("RAILWATCH_COMMAND_SAMPLE_RATE", 1.0),
        scheduled_tasks: env_float("RAILWATCH_SCHEDULED_TASK_SAMPLE_RATE", 1.0),
        channels: env_float("RAILWATCH_CHANNEL_SAMPLE_RATE", 1.0),
        exceptions: env_float("RAILWATCH_EXCEPTION_SAMPLE_RATE", 1.0)
      }
      self.ignore = RECORD_TYPES.select { |t| env_bool("RAILWATCH_IGNORE_#{t.to_s.upcase}", false) }
      @log_level = (ENV["RAILWATCH_LOG_LEVEL"] || "info").to_sym
      @capture_request_payload = env_bool("RAILWATCH_CAPTURE_REQUEST_PAYLOAD", false)
      @capture_exception_source = env_bool("RAILWATCH_CAPTURE_EXCEPTION_SOURCE_CODE", true)
      @capture_exception_locals = env_bool("RAILWATCH_CAPTURE_EXCEPTION_LOCALS", false)
      @redact_headers = ENV.fetch("RAILWATCH_REDACT_HEADERS", "Authorization,Cookie,Set-Cookie,Proxy-Authorization,X-CSRF-Token,X-XSRF-TOKEN").split(",").map(&:strip)
      @redact_params = ENV.fetch("RAILWATCH_REDACT_PARAMS", "password,password_confirmation,authenticity_token,_token").split(",").map(&:strip)
      # At least Execution::MAX_RECORDS: finish_execution writes a kept
      # execution's whole tree into this queue at once, and a queue smaller
      # than the tree drops the tree's own oldest records -- the outgoing
      # requests and first queries at the top of a long job.
      @buffer_size = env_int("RAILWATCH_BUFFER_SIZE", 10_000)
      # A record count does not bound memory: 10,000 records is a few
      # megabytes of ordinary telemetry, or a gigabyte of captured
      # attachments. These are the byte ceilings that do -- one execution's
      # tree, the reporter queue, and one delivery.
      @buffer_bytes = env_int("RAILWATCH_BUFFER_BYTES", 16 * 1024 * 1024)
      @execution_buffer_bytes = env_int("RAILWATCH_EXECUTION_BUFFER_BYTES", 8 * 1024 * 1024)
      @batch_bytes = env_int("RAILWATCH_BATCH_BYTES", 8 * 1024 * 1024)
      @backpressure = env_bool("RAILWATCH_BACKPRESSURE", true)
      self.backpressure_high_water = env_float("RAILWATCH_BACKPRESSURE_HIGH_WATER", 0.8)
      @flush_interval = env_float("RAILWATCH_FLUSH_INTERVAL", 2.0)
      @flush_threshold = env_int("RAILWATCH_FLUSH_THRESHOLD", 500)
      @connect_timeout = env_float("RAILWATCH_CONNECT_TIMEOUT", 1.0)
      @timeout = env_float("RAILWATCH_TIMEOUT", 3.0)
      @shutdown_timeout = env_float("RAILWATCH_SHUTDOWN_TIMEOUT", 2.0)
      @slow_query_threshold_ms = env_float("RAILWATCH_SLOW_QUERY_MS", 5.0)
      @n_plus_one_threshold = env_int("RAILWATCH_N_PLUS_ONE_THRESHOLD", 5)
      @max_view_renders_per_execution = 20
      @ignored_cache_key_prefixes = []
      @capture_default_vendor_commands = env_bool("RAILWATCH_CAPTURE_DEFAULT_VENDOR_COMMANDS", false)
      @capture_default_vendor_cache_keys = env_bool("RAILWATCH_CAPTURE_DEFAULT_VENDOR_CACHE_KEYS", false)
      @capture_framework_events = env_bool("RAILWATCH_CAPTURE_FRAMEWORK_EVENTS", false)
      @on_unrecoverable = nil
      @beacon_enabled = env_bool("RAILWATCH_BEACON", true)
      # The beacon is unauthenticated and forces Railwatch.keep! for browser
      # errors, so without a ceiling anyone can spend an app's event quota
      # from a shell. Per client IP per minute; 0 turns the limit off, and a
      # negative value is normalized to 0 rather than left to mean anything.
      @beacon_rate_limit = [ env_int("RAILWATCH_BEACON_RATE_LIMIT", 120), 0 ].max
      # The same three defences a hosted product puts in front of a public
      # browser-ingest endpoint (Sentry's are allowed domains, per-key rate
      # limits and spike protection): a per-IP limit above, a ceiling on the
      # whole endpoint so one busy minute cannot fill the telemetry database,
      # and an origin allowlist. None is authentication -- a public endpoint
      # cannot have any, since the credential would be in the page -- they
      # bound abuse. 0 disables a limit; beacon_enabled = false removes the
      # endpoint's work entirely.
      @beacon_global_rate_limit = [ env_int("RAILWATCH_BEACON_GLOBAL_RATE_LIMIT", 6_000), 0 ].max
      # Extra origins allowed to beacon, beyond the app's own. Same meaning
      # as Sentry's allowed domains: "https://app.example.com", or a host on
      # its own. Empty means same-origin only.
      @beacon_allowed_origins = ENV["RAILWATCH_BEACON_ALLOWED_ORIGINS"]&.split(",")&.map(&:strip)&.reject(&:empty?) || []
      @debug = env_bool("RAILWATCH_DEBUG", false)
      # Tail-based sampling: a head-sampled-out execution is still kept when
      # it ran at least this long, raised, or Railwatch.keep! was called. nil = off.
      @tail_sample_slow_ms = ENV["RAILWATCH_TAIL_SAMPLE_SLOW_MS"]&.then { |v| Float(v) }
      # Failure context: how many of a head-sampled-out execution's child
      # records to hold in a ring so an unhandled exception can ship what led
      # up to it. 0 = off, which is the default -- a sampled-out execution
      # then builds and buffers nothing, exactly as before.
      @failure_context = env_int("RAILWATCH_FAILURE_CONTEXT", 0)
      @propagate_traces = env_bool("RAILWATCH_PROPAGATE_TRACES", true)
      @trace_propagation_hosts = ENV["RAILWATCH_TRACE_PROPAGATION_HOSTS"]&.split(",")&.map(&:strip)
      @health_interval = env_float("RAILWATCH_HEALTH_INTERVAL", 15.0)
      @capture_query_explain = env_bool("RAILWATCH_CAPTURE_QUERY_EXPLAIN", false)
      @explain_threshold_ms = env_float("RAILWATCH_EXPLAIN_THRESHOLD_MS", 100.0)
      # SQL literals routinely carry email addresses, tokens, and other
      # customer data. Query records therefore carry only the normalized
      # statement shape unless an application deliberately opts in.
      @capture_sql_values = env_bool("RAILWATCH_CAPTURE_SQL_VALUES", false)
      @ignored_exceptions = ENV["RAILWATCH_IGNORED_EXCEPTIONS"]&.split(",")&.map(&:strip) || DEFAULT_IGNORED_EXCEPTIONS.dup
      @capture_rescued_exceptions = env_bool("RAILWATCH_CAPTURE_RESCUED_EXCEPTIONS", true)
      # Sampling profiler: profile this fraction of sampled-in requests/jobs
      # (0 = off), and always profile ones slower than profile_slow_ms once
      # tail sampling keeps them. Uses vernier when available, else stackprof.
      @profile_sample = env_float("RAILWATCH_PROFILE_SAMPLE_RATE", 0.0)
      @profile_slow_ms = ENV["RAILWATCH_PROFILE_SLOW_MS"]&.then { |v| Float(v) }
      @profile_interval_us = env_int("RAILWATCH_PROFILE_INTERVAL_US", 1_000)
      @profiler = ENV["RAILWATCH_PROFILER"]&.to_sym
      @capture_job_arguments = env_bool("RAILWATCH_CAPTURE_JOB_ARGUMENTS", false)
      @capture_job_retry_errors = env_bool("RAILWATCH_CAPTURE_JOB_RETRY_ERRORS", false)
      @capture_response_body_on_error = env_bool("RAILWATCH_CAPTURE_RESPONSE_BODY_ON_ERROR", false)
      # Prompts and completions are whatever the app sent a provider, so
      # they are off until an operator opts in. Token counts, model, and
      # cost -- the reason the record exists -- are always captured.
      @capture_llm_content = env_bool("RAILWATCH_CAPTURE_LLM_CONTENT", false)
      @max_attachment_bytes = env_int("RAILWATCH_MAX_ATTACHMENT_BYTES", 1_048_576)
      # Release health: one `session` record per browser tab (the beacon
      # client) and per authenticated/cookied server session (Railwatch::Sessions).
      @track_sessions = env_bool("RAILWATCH_TRACK_SESSIONS", true)
      @session_flush_interval = env_float("RAILWATCH_SESSION_FLUSH_INTERVAL", 60.0)
      @session_timeout = env_float("RAILWATCH_SESSION_TIMEOUT", 1800.0)
      # Interactive sessions: a `bin/rails console` process captures nothing
      # at all, and a typed/piped `bin/rails runner` ships its command record
      # but not its exception. A deployed script always reports.
      @capture_console = env_bool("RAILWATCH_CAPTURE_CONSOLE", false)
      @interactive_runner_paths = ENV["RAILWATCH_INTERACTIVE_RUNNER_PATHS"]&.split(",")&.map(&:strip) ||
        DEFAULT_INTERACTIVE_RUNNER_PATHS.dup
      @ignored_request_paths = ENV["RAILWATCH_IGNORED_REQUEST_PATHS"]&.split(",")&.map(&:strip)&.reject(&:empty?) ||
        DEFAULT_IGNORED_REQUEST_PATHS.dup
      @user_resolver = nil
      @beacon_user_resolver = nil
      @fingerprint_resolver = nil
      @redactors = Hash.new { |h, k| h[k] = [] }
      @rejectors = Hash.new { |h, k| h[k] = [] }
      @before_ingest = []
    end

    def deploy=(value)
      @deploy = value
      @deploy_source = "config/initializers/railwatch.rb"
      @deploy_overridden = true
    end

    def detect_deploy=(value)
      @detect_deploy = value
      detect_release unless @deploy_overridden
    end

    def user(&block)
      @user_resolver = block
    end

    # Railwatch.beacon_user { |request| ... }: who is behind a browser beacon.
    # The beacon is handled by the gem's own engine controller, outside the
    # app's ApplicationController, so an app that authenticates in a
    # before_action (a signed session cookie looked up per request, say)
    # has not run it by the time the beacon is read. Return the user object
    # the `user` block understands, or nil. Not needed when the app sets
    # Current.user in middleware or uses Warden, which the default resolution
    # already reads.
    def beacon_user(&block)
      @beacon_user_resolver = block
    end

    # Railwatch.fingerprint { |error, default| ... }: one block, called with
    # the error and the parts Railwatch would have hashed. Passing no block
    # clears it.
    def fingerprint(&block)
      @fingerprint_resolver = block
    end

    def enabled?
      @enabled && (local? || token.present?)
    end

    # :local writes telemetry into the engine's own database in-process;
    # anything else ships it to ingest_url over HTTPS.
    def local? = transport.to_s == "local"

    # The receiver admits an unseen delivery for seven days; queueing one for
    # longer cannot help.
    MAX_EXPORT_AGE = 7 * 24 * 60 * 60

    # Mirroring is a thing an embedded install opts into; it is meaningless
    # for an install that is already sending everything over HTTP.
    def export? = export_enabled && local? && export_problem.nil?

    # Why export is configured but unusable, or nil when it is fine. The
    # doctor reports this; nothing silently half-enables.
    def export_problem
      return nil unless export_enabled
      return "export needs transport :local; an :http install already sends everything" unless local?
      return "RAILWATCH_EXPORT_POLICY #{export_policy} is not implemented" unless export_policy.to_s == "everything"
      return "no export token: set RAILWATCH_EXPORT_TOKEN or RAILWATCH_TOKEN" if resolved_export_token.to_s.empty?
      return "no export url: set RAILWATCH_EXPORT_URL or RAILWATCH_INGEST_URL" if resolved_export_url.to_s.empty?
      return "export url must be HTTPS (or set RAILWATCH_ALLOW_HTTP=true)" unless url_allowed?(resolved_export_url)
      # Past this a receiver stops recognising a delivery's id, so holding one
      # any longer just means discovering later that it can never be sent.
      if export_max_age > MAX_EXPORT_AGE
        return "RAILWATCH_EXPORT_MAX_AGE_SECONDS cannot exceed #{MAX_EXPORT_AGE} (the receiver stops recognising a delivery past that)"
      end

      nil
    end

    # The receiver, and the credential we are bound to it with. Both fall back
    # to the ordinary ingest settings so switching an install from embedded to
    # cloud needs no second set of values.
    def resolved_export_url
      url = export_url.presence || (ingest_url.presence && URI.join(ingest_url, "/ingest").to_s)
      url&.sub(%r{/\z}, "")
    rescue URI::InvalidURIError
      nil
    end

    def resolved_export_token = export_token.presence || token

    # Absolute path of the writer socket, or nil when the writer is off.
    def writer_socket_path
      path = writer_socket.to_s
      return nil if path.empty?

      root = defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.to_s : Dir.pwd
      File.expand_path(path, root)
    end

    # Who the embedded dashboard shows as the signed-in operator. A host
    # passes a lambda taking the request (cookies, warden, whatever it uses)
    # and returning a User, {id:, name:, email:} or nil. Authentication and
    # authorisation stay the host's job: put the mount behind its own
    # constraint. This only names the person for comments and saved views.
    # Both halves present. Read late (not at boot) so credentials set from an
    # initializer, an env var or the configure task all count.
    def http_basic_auth_configured?
      http_basic_auth_user.to_s.strip != "" && http_basic_auth_password.to_s.strip != ""
    end

    # Whether the request carries the configured HTTP Basic credentials.
    # False when Basic is on and nothing is configured (closed), true when
    # Basic is off (the host's base controller or routes constraint is the
    # gate then). Shared by the dashboard controller and the live channel.
    def http_basic_auth_ok?(request)
      return true unless http_basic_auth_enabled
      return false unless http_basic_auth_configured?

      ActionController::HttpAuthentication::Basic.authenticate(request) do |user, password|
        ActiveSupport::SecurityUtils.secure_compare(user, http_basic_auth_user.to_s) &
          ActiveSupport::SecurityUtils.secure_compare(password, http_basic_auth_password.to_s)
      end == true
    end

    # Which gate is in force, for the doctor, the boot warning and the live
    # channel. :basic when HTTP Basic is on (closed until credentials exist),
    # :controller when the host named its own base controller, :resolver when
    # it gave a dashboard_user that can refuse, :open when it said the
    # dashboard is deliberately public, and :undeclared when Basic is off and
    # none of those is true -- which usually means a routes constraint the
    # gem cannot see, and might mean nothing at all.
    def dashboard_gate
      return :basic if http_basic_auth_enabled
      return :controller unless base_controller_class == DEFAULT_BASE_CONTROLLER
      return :resolver if dashboard_user
      return :open if dashboard_open

      :undeclared
    end

    # Whether a live-update subscription is allowed. Action Cable runs on the
    # host's own /cable endpoint, which a routes constraint around the
    # engine's mount does not cover and a base controller cannot reach, so an
    # undeclared gate refuses rather than assuming.
    def dashboard_channel_allowed?(request)
      case dashboard_gate
      when :basic then http_basic_auth_ok?(request)
      when :resolver then !(dashboard_user.respond_to?(:call) ? dashboard_user.call(request) : dashboard_user).nil?
      when :open, :controller then true
      else false
      end
    end

    def resolve_dashboard_user(request)
      resolved = dashboard_user.respond_to?(:call) ? dashboard_user.call(request) : dashboard_user
      case resolved
      when User then resolved
      when Hash then User.new(id: resolved[:id] || User::ID, name: resolved[:name].to_s.presence || "Operator", email: resolved[:email])
      else User.default
      end
    end

    def ingest_url_allowed?
      url_allowed?(ingest_url)
    end

    # The same policy, applied to whatever URL is actually about to be
    # requested. A transport pointed at an explicit endpoint must be judged on
    # that endpoint: approving it because some other configured URL happens to
    # be HTTPS would put the token on the wire in plaintext.
    def url_allowed?(url)
      uri = url.is_a?(URI::Generic) ? url : URI.parse(url.to_s)
      return true if uri.scheme == "https"
      return false unless uri.scheme == "http"

      allow_http || %w[localhost 127.0.0.1 ::1 [::1]].include?(uri.host)
    rescue URI::InvalidURIError
      false
    end

    attr_reader :ignore

    # Stored alongside a frozen Set so the per-record ignored? check is a
    # single Set lookup instead of an Array#include? scan on every record.
    def ignore=(value)
      unknown = Array(value) - RECORD_TYPES
      raise ArgumentError, "unknown record type(s): #{unknown.join(', ')}" if unknown.any?

      @ignore = value
      @ignored_set = Set.new(value).freeze
    end

    def ignored?(type)
      @ignored_set.include?(type)
    end

    def sample_rate(kind)
      @sample.fetch(kind, 1.0).to_f.clamp(0.0, 1.0)
    end

    def backpressure_high_water=(value)
      fraction = Float(value, exception: false)
      @backpressure_high_water = if fraction&.finite? && fraction.positive? && fraction <= 1.0
        fraction
      else
        0.8
      end
    end

    def environment_name
      @environment || (defined?(Rails) ? Rails.env.to_s : "production")
    end

    # Matches Railwatch.reject_cache_keys entries and DEFAULT_VENDOR_CACHE_KEYS
    # against a cache key. A Regexp is used as-is. A String starting with "^"
    # or containing another regex metacharacter is compiled as a Regexp; a
    # String ending in "*" matches as a prefix; any other String must match
    # exactly (so "session:" no longer accidentally matches "usersession:").
    CACHE_KEY_METACHARS = /[.?+()|{}\[\]]/
    def self.match_cache_key?(pattern, key)
      case pattern
      when Regexp
        pattern.match?(key)
      when String
        if pattern.start_with?("^") || CACHE_KEY_METACHARS.match?(pattern)
          Regexp.new(pattern).match?(key)
        elsif pattern.end_with?("*")
          key.start_with?(pattern[0..-2])
        else
          key == pattern
        end
      else
        false
      end
    end

    private

    def detect_release
      @deploy_source = nil
      if @detect_deploy
        @deploy = ReleaseDetector.detect(project_root: @project_root) { |source| @deploy_source = source }
        return
      end

      @deploy_source = %w[RAILWATCH_DEPLOY KAMAL_VERSION].find { |key| ENV[key].to_s.strip != "" }
      value = @deploy_source ? ENV[@deploy_source].to_s.strip : ""
      @deploy = ReleaseDetector::SHA.match?(value) ? value[0, 12] : value
      @deploy = nil if @deploy.empty?
    end

    def env_bool(key, default)
      return default unless ENV.key?(key)
      %w[1 true yes on].include?(ENV[key].to_s.downcase)
    end

    # String#to_f/#to_i turn a typo into 0.0/0 -- a zero buffer, timeout, or
    # interval -- so parse strictly and keep the documented default instead.
    def env_float(key, default)
      ENV.key?(key) ? Float(ENV[key], exception: false) || default : default
    end

    def env_int(key, default)
      ENV.key?(key) ? Integer(ENV[key], 10, exception: false) || default : default
    end
  end
end
