# frozen_string_literal: true

module Lantern
  # All settings, each overridable by a LANTERN_* env var. Mirrors the shape of
  # Laravel Nightwatch's config so the two products document the same knobs.
  class Configuration
    RECORD_TYPES = %i[queries cache_events mail broadcasts notifications outgoing_requests
                      storage_ops view_renders logs transactions deprecations sessions].freeze

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
    # Lantern's own browser transport in another request execution (the
    # beacon). Apps can replace this list through LANTERN_IGNORED_REQUEST_PATHS
    # or append exact paths/regexps in their initializer.
    DEFAULT_IGNORED_REQUEST_PATHS = %w[/up /lantern/beacon].freeze

    # Exceptions that are routine 4xx plumbing rather than application bugs.
    # The Rails-relevant subset of Sentry's own defaults
    # (Sentry::Configuration::IGNORE_DEFAULT + PUMA_IGNORE_DEFAULT and
    # Sentry::Rails::Configuration::IGNORE_DEFAULT), so a Sentry app migrating
    # to Lantern sees the same signal-to-noise out of the box.
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

    attr_accessor :enabled, :token, :ingest_url, :deploy, :server, :environment,
                  :sample, :log_level, :capture_request_payload,
                  :capture_exception_source, :capture_exception_locals, :redact_headers, :redact_params,
                  :buffer_size, :buffer_bytes, :execution_buffer_bytes, :batch_bytes,
                  :backpressure,
                  :flush_interval, :flush_threshold,
                  :connect_timeout, :timeout, :shutdown_timeout,
                  :slow_query_threshold_ms, :n_plus_one_threshold,
                  :max_view_renders_per_execution, :ignored_cache_key_prefixes,
                  :beacon_enabled, :beacon_rate_limit, :debug, :capture_default_vendor_commands,
                  :capture_default_vendor_cache_keys, :on_unrecoverable,
                  :capture_framework_events,
                  :tail_sample_slow_ms, :failure_context, :propagate_traces, :trace_propagation_hosts,
                  :health_interval, :capture_query_explain, :explain_threshold_ms,
                  :capture_sql_values,
                  :ignored_exceptions, :capture_rescued_exceptions,
                  :profile_sample, :profile_slow_ms, :profile_interval_us, :profiler,
                  :capture_job_arguments, :capture_job_retry_errors, :capture_response_body_on_error, :max_attachment_bytes,
                  :track_sessions, :session_flush_interval, :session_timeout,
                  :capture_console, :interactive_runner_paths, :ignored_request_paths

    attr_reader :user_resolver, :beacon_user_resolver, :fingerprint_resolver, :redactors, :rejectors, :before_ingest,
                :backpressure_high_water

    def initialize
      @enabled = env_bool("LANTERN_ENABLED", true)
      @token = ENV["LANTERN_TOKEN"]
      @ingest_url = ENV.fetch("LANTERN_INGEST_URL", "https://lantern.rebulk.com")
      @deploy = ENV["LANTERN_DEPLOY"] || ENV["KAMAL_VERSION"] || ENV["GIT_REV"]
      # Kamal names the container after the host plus a container id, so a
      # bare hostname changes on every deploy and never matches the host the
      # post-deploy hook registers as expected. KAMAL_HOST, which Kamal sets
      # in every container it starts, is that host.
      @server = ENV["LANTERN_SERVER"] || ENV["KAMAL_HOST"] || Socket.gethostname
      @environment = nil # resolved lazily from Rails.env
      @sample = {
        requests: env_float("LANTERN_REQUEST_SAMPLE_RATE", 1.0),
        jobs: env_float("LANTERN_JOB_SAMPLE_RATE", 1.0),
        commands: env_float("LANTERN_COMMAND_SAMPLE_RATE", 1.0),
        scheduled_tasks: env_float("LANTERN_SCHEDULED_TASK_SAMPLE_RATE", 1.0),
        channels: env_float("LANTERN_CHANNEL_SAMPLE_RATE", 1.0),
        exceptions: env_float("LANTERN_EXCEPTION_SAMPLE_RATE", 1.0)
      }
      self.ignore = RECORD_TYPES.select { |t| env_bool("LANTERN_IGNORE_#{t.to_s.upcase}", false) }
      @log_level = (ENV["LANTERN_LOG_LEVEL"] || "info").to_sym
      @capture_request_payload = env_bool("LANTERN_CAPTURE_REQUEST_PAYLOAD", false)
      @capture_exception_source = env_bool("LANTERN_CAPTURE_EXCEPTION_SOURCE_CODE", true)
      @capture_exception_locals = env_bool("LANTERN_CAPTURE_EXCEPTION_LOCALS", false)
      @redact_headers = ENV.fetch("LANTERN_REDACT_HEADERS", "Authorization,Cookie,Set-Cookie,Proxy-Authorization,X-CSRF-Token,X-XSRF-TOKEN").split(",").map(&:strip)
      @redact_params = ENV.fetch("LANTERN_REDACT_PARAMS", "password,password_confirmation,authenticity_token,_token").split(",").map(&:strip)
      # At least Execution::MAX_RECORDS: finish_execution writes a kept
      # execution's whole tree into this queue at once, and a queue smaller
      # than the tree drops the tree's own oldest records -- the outgoing
      # requests and first queries at the top of a long job.
      @buffer_size = env_int("LANTERN_BUFFER_SIZE", 10_000)
      # A record count does not bound memory: 10,000 records is a few
      # megabytes of ordinary telemetry, or a gigabyte of captured
      # attachments. These are the byte ceilings that do -- one execution's
      # tree, the reporter queue, and one delivery.
      @buffer_bytes = env_int("LANTERN_BUFFER_BYTES", 16 * 1024 * 1024)
      @execution_buffer_bytes = env_int("LANTERN_EXECUTION_BUFFER_BYTES", 8 * 1024 * 1024)
      @batch_bytes = env_int("LANTERN_BATCH_BYTES", 8 * 1024 * 1024)
      @backpressure = env_bool("LANTERN_BACKPRESSURE", true)
      self.backpressure_high_water = env_float("LANTERN_BACKPRESSURE_HIGH_WATER", 0.8)
      @flush_interval = env_float("LANTERN_FLUSH_INTERVAL", 2.0)
      @flush_threshold = env_int("LANTERN_FLUSH_THRESHOLD", 500)
      @connect_timeout = env_float("LANTERN_CONNECT_TIMEOUT", 1.0)
      @timeout = env_float("LANTERN_TIMEOUT", 3.0)
      @shutdown_timeout = env_float("LANTERN_SHUTDOWN_TIMEOUT", 2.0)
      @slow_query_threshold_ms = env_float("LANTERN_SLOW_QUERY_MS", 5.0)
      @n_plus_one_threshold = env_int("LANTERN_N_PLUS_ONE_THRESHOLD", 5)
      @max_view_renders_per_execution = 20
      @ignored_cache_key_prefixes = []
      @capture_default_vendor_commands = env_bool("LANTERN_CAPTURE_DEFAULT_VENDOR_COMMANDS", false)
      @capture_default_vendor_cache_keys = env_bool("LANTERN_CAPTURE_DEFAULT_VENDOR_CACHE_KEYS", false)
      @capture_framework_events = env_bool("LANTERN_CAPTURE_FRAMEWORK_EVENTS", false)
      @on_unrecoverable = nil
      @beacon_enabled = env_bool("LANTERN_BEACON", true)
      # The beacon is unauthenticated and forces Lantern.keep! for browser
      # errors, so without a ceiling anyone can spend an app's event quota
      # from a shell. Per client IP per minute; 0 turns the limit off, and a
      # negative value is normalized to 0 rather than left to mean anything.
      @beacon_rate_limit = [ env_int("LANTERN_BEACON_RATE_LIMIT", 120), 0 ].max
      @debug = env_bool("LANTERN_DEBUG", false)
      # Tail-based sampling: a head-sampled-out execution is still kept when
      # it ran at least this long, raised, or Lantern.keep! was called. nil = off.
      @tail_sample_slow_ms = ENV["LANTERN_TAIL_SAMPLE_SLOW_MS"]&.then { |v| Float(v) }
      # Failure context: how many of a head-sampled-out execution's child
      # records to hold in a ring so an unhandled exception can ship what led
      # up to it. 0 = off, which is the default -- a sampled-out execution
      # then builds and buffers nothing, exactly as before.
      @failure_context = env_int("LANTERN_FAILURE_CONTEXT", 0)
      @propagate_traces = env_bool("LANTERN_PROPAGATE_TRACES", true)
      @trace_propagation_hosts = ENV["LANTERN_TRACE_PROPAGATION_HOSTS"]&.split(",")&.map(&:strip)
      @health_interval = env_float("LANTERN_HEALTH_INTERVAL", 15.0)
      @capture_query_explain = env_bool("LANTERN_CAPTURE_QUERY_EXPLAIN", false)
      @explain_threshold_ms = env_float("LANTERN_EXPLAIN_THRESHOLD_MS", 100.0)
      # SQL literals routinely carry email addresses, tokens, and other
      # customer data. Query records therefore carry only the normalized
      # statement shape unless an application deliberately opts in.
      @capture_sql_values = env_bool("LANTERN_CAPTURE_SQL_VALUES", false)
      @ignored_exceptions = ENV["LANTERN_IGNORED_EXCEPTIONS"]&.split(",")&.map(&:strip) || DEFAULT_IGNORED_EXCEPTIONS.dup
      @capture_rescued_exceptions = env_bool("LANTERN_CAPTURE_RESCUED_EXCEPTIONS", true)
      # Sampling profiler: profile this fraction of sampled-in requests/jobs
      # (0 = off), and always profile ones slower than profile_slow_ms once
      # tail sampling keeps them. Uses vernier when available, else stackprof.
      @profile_sample = env_float("LANTERN_PROFILE_SAMPLE_RATE", 0.0)
      @profile_slow_ms = ENV["LANTERN_PROFILE_SLOW_MS"]&.then { |v| Float(v) }
      @profile_interval_us = env_int("LANTERN_PROFILE_INTERVAL_US", 1_000)
      @profiler = ENV["LANTERN_PROFILER"]&.to_sym
      @capture_job_arguments = env_bool("LANTERN_CAPTURE_JOB_ARGUMENTS", false)
      @capture_job_retry_errors = env_bool("LANTERN_CAPTURE_JOB_RETRY_ERRORS", false)
      @capture_response_body_on_error = env_bool("LANTERN_CAPTURE_RESPONSE_BODY_ON_ERROR", false)
      @max_attachment_bytes = env_int("LANTERN_MAX_ATTACHMENT_BYTES", 1_048_576)
      # Release health: one `session` record per browser tab (the beacon
      # client) and per authenticated/cookied server session (Lantern::Sessions).
      @track_sessions = env_bool("LANTERN_TRACK_SESSIONS", true)
      @session_flush_interval = env_float("LANTERN_SESSION_FLUSH_INTERVAL", 60.0)
      @session_timeout = env_float("LANTERN_SESSION_TIMEOUT", 1800.0)
      # Interactive sessions: a `bin/rails console` process captures nothing
      # at all, and a typed/piped `bin/rails runner` ships its command record
      # but not its exception. A deployed script always reports.
      @capture_console = env_bool("LANTERN_CAPTURE_CONSOLE", false)
      @interactive_runner_paths = ENV["LANTERN_INTERACTIVE_RUNNER_PATHS"]&.split(",")&.map(&:strip) ||
        DEFAULT_INTERACTIVE_RUNNER_PATHS.dup
      @ignored_request_paths = ENV["LANTERN_IGNORED_REQUEST_PATHS"]&.split(",")&.map(&:strip)&.reject(&:empty?) ||
        DEFAULT_IGNORED_REQUEST_PATHS.dup
      @user_resolver = nil
      @beacon_user_resolver = nil
      @fingerprint_resolver = nil
      @redactors = Hash.new { |h, k| h[k] = [] }
      @rejectors = Hash.new { |h, k| h[k] = [] }
      @before_ingest = []
    end

    def user(&block)
      @user_resolver = block
    end

    # Lantern.beacon_user { |request| ... }: who is behind a browser beacon.
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

    # Lantern.fingerprint { |error, default| ... }: one block, called with
    # the error and the parts Lantern would have hashed. Passing no block
    # clears it.
    def fingerprint(&block)
      @fingerprint_resolver = block
    end

    def enabled?
      @enabled && token.present?
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

    # Matches Lantern.reject_cache_keys entries and DEFAULT_VENDOR_CACHE_KEYS
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
