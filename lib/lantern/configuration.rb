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

    SAMPLE_DEFAULTS = {
      requests: 1.0,
      jobs: 1.0,
      commands: 1.0,
      scheduled_tasks: 1.0,
      exceptions: 1.0
    }.freeze

    SAMPLE_ENV_KEYS = {
      requests: "LANTERN_REQUEST_SAMPLE_RATE",
      jobs: "LANTERN_JOB_SAMPLE_RATE",
      commands: "LANTERN_COMMAND_SAMPLE_RATE",
      scheduled_tasks: "LANTERN_SCHEDULED_TASK_SAMPLE_RATE",
      exceptions: "LANTERN_EXCEPTION_SAMPLE_RATE"
    }.freeze

    # Runtime-safe defaults and accepted domains for every numeric setting.
    # Invalid environment/configuration values are reported but replaced with
    # these defaults so observability configuration can never break app boot
    # or reach a negative slice, timeout, or condition-variable wait.
    NUMERIC_SETTINGS = {
      buffer_size: { env: "LANTERN_BUFFER_SIZE", default: 10_000, integer: true, min: 1 },
      flush_interval: { env: "LANTERN_FLUSH_INTERVAL", default: 2.0, min: 0, exclusive_min: true },
      flush_threshold: { env: "LANTERN_FLUSH_THRESHOLD", default: 500, integer: true, min: 1 },
      connect_timeout: { env: "LANTERN_CONNECT_TIMEOUT", default: 1.0, min: 0, exclusive_min: true },
      timeout: { env: "LANTERN_TIMEOUT", default: 3.0, min: 0, exclusive_min: true },
      shutdown_timeout: { env: "LANTERN_SHUTDOWN_TIMEOUT", default: 2.0, min: 0 },
      slow_query_threshold_ms: { env: "LANTERN_SLOW_QUERY_MS", default: 5.0, min: 0 },
      n_plus_one_threshold: { env: "LANTERN_N_PLUS_ONE_THRESHOLD", default: 5, integer: true, min: 1 },
      max_view_renders_per_execution: { default: 20, integer: true, min: 0 },
      tail_sample_slow_ms: { env: "LANTERN_TAIL_SAMPLE_SLOW_MS", default: nil, min: 0, allow_nil: true },
      failure_context: { env: "LANTERN_FAILURE_CONTEXT", default: 0, integer: true, min: 0 },
      health_interval: { env: "LANTERN_HEALTH_INTERVAL", default: 15.0, min: 0, exclusive_min: true },
      explain_threshold_ms: { env: "LANTERN_EXPLAIN_THRESHOLD_MS", default: 100.0, min: 0 },
      profile_sample: { env: "LANTERN_PROFILE_SAMPLE_RATE", default: 0.0, min: 0, max: 1 },
      profile_slow_ms: { env: "LANTERN_PROFILE_SLOW_MS", default: nil, min: 0, allow_nil: true },
      profile_interval_us: { env: "LANTERN_PROFILE_INTERVAL_US", default: 1_000, integer: true, min: 1 },
      max_attachment_bytes: { env: "LANTERN_MAX_ATTACHMENT_BYTES", default: 1_048_576, integer: true, min: 1 },
      session_flush_interval: { env: "LANTERN_SESSION_FLUSH_INTERVAL", default: 60.0, min: 0, exclusive_min: true },
      session_timeout: { env: "LANTERN_SESSION_TIMEOUT", default: 1800.0, min: 0, exclusive_min: true }
    }.freeze

    attr_accessor :enabled, :token, :ingest_url, :deploy, :server, :environment,
                  :sample, :log_level, :capture_request_payload,
                  :capture_exception_source, :capture_exception_locals, :redact_headers, :redact_params,
                  :buffer_size, :flush_interval, :flush_threshold,
                  :connect_timeout, :timeout, :shutdown_timeout,
                  :slow_query_threshold_ms, :n_plus_one_threshold,
                  :max_view_renders_per_execution, :ignored_cache_key_prefixes,
                  :beacon_enabled, :debug, :capture_default_vendor_commands,
                  :capture_default_vendor_cache_keys, :on_unrecoverable,
                  :capture_framework_events,
                  :tail_sample_slow_ms, :failure_context, :propagate_traces, :trace_propagation_hosts,
                  :health_interval, :capture_query_explain, :explain_threshold_ms,
                  :ignored_exceptions, :capture_rescued_exceptions,
                  :profile_sample, :profile_slow_ms, :profile_interval_us, :profiler,
                  :capture_job_arguments, :capture_response_body_on_error, :max_attachment_bytes,
                  :track_sessions, :session_flush_interval, :session_timeout,
                  :capture_console, :interactive_runner_paths, :ignored_request_paths

    attr_reader :user_resolver, :beacon_user_resolver, :fingerprint_resolver, :redactors, :rejectors, :before_ingest

    def initialize
      @numeric_errors = {}
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
      @sample = SAMPLE_DEFAULTS.to_h { |kind, default| [ kind, env_float(SAMPLE_ENV_KEYS.fetch(kind), default) ] }
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
      @debug = env_bool("LANTERN_DEBUG", false)
      # Tail-based sampling: a head-sampled-out execution is still kept when
      # it ran at least this long, raised, or Lantern.keep! was called. nil = off.
      @tail_sample_slow_ms = env_optional_float("LANTERN_TAIL_SAMPLE_SLOW_MS")
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
      @ignored_exceptions = ENV["LANTERN_IGNORED_EXCEPTIONS"]&.split(",")&.map(&:strip) || DEFAULT_IGNORED_EXCEPTIONS.dup
      @capture_rescued_exceptions = env_bool("LANTERN_CAPTURE_RESCUED_EXCEPTIONS", true)
      # Sampling profiler: profile this fraction of sampled-in requests/jobs
      # (0 = off), and always profile ones slower than profile_slow_ms once
      # tail sampling keeps them. Uses vernier when available, else stackprof.
      @profile_sample = env_float("LANTERN_PROFILE_SAMPLE_RATE", 0.0)
      @profile_slow_ms = env_optional_float("LANTERN_PROFILE_SLOW_MS")
      @profile_interval_us = env_int("LANTERN_PROFILE_INTERVAL_US", 1_000)
      @profiler = ENV["LANTERN_PROFILER"]&.to_sym
      @capture_job_arguments = env_bool("LANTERN_CAPTURE_JOB_ARGUMENTS", false)
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
      validate_numeric_settings!(:environment)
      validate_sample_settings!(:environment)
    end

    # Starts a new configure transaction. Old initializer errors remain, but
    # repaired code-level values clear stale config.* diagnostics.
    def prepare_for_configuration!
      @numeric_errors.delete_if { |key, _| key.start_with?("config.") }
      self
    end

    # Called after Lantern.configure yields and by lantern:doctor. Invalid
    # values fall back to known-safe defaults and remain visible to doctor.
    def validate!
      validate_numeric_settings!(:configuration)
      validate_sample_settings!(:configuration)
      self
    end

    def numeric_errors
      @numeric_errors.dup
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

    def env_float(key, default)
      return default unless ENV.key?(key)

      Float(ENV[key])
    rescue ArgumentError, TypeError
      invalid_numeric!(key, ENV[key], "must be a number", default)
      default
    end

    def env_int(key, default)
      return default unless ENV.key?(key)

      Integer(ENV[key], 10)
    rescue ArgumentError, TypeError
      invalid_numeric!(key, ENV[key], "must be an integer", default)
      default
    end

    def env_optional_float(key)
      return nil unless ENV.key?(key)

      Float(ENV[key])
    rescue ArgumentError, TypeError
      invalid_numeric!(key, ENV[key], "must be a number or unset", nil)
      nil
    end

    def validate_numeric_settings!(source)
      NUMERIC_SETTINGS.each do |attribute, rule|
        value = public_send(attribute)
        next if valid_numeric?(value, rule)

        label = source == :environment && rule[:env] ? rule[:env] : "config.#{attribute}"
        invalid_numeric!(label, value, numeric_requirement(rule), rule[:default])
        public_send("#{attribute}=", rule[:default])
      end
    end

    def validate_sample_settings!(source)
      unless @sample.is_a?(Hash)
        invalid_numeric!("config.sample", @sample, "must be a hash of finite rates", SAMPLE_DEFAULTS)
        @sample = {}
      end
      @sample = @sample.dup if @sample.frozen?
      SAMPLE_DEFAULTS.each do |kind, default|
        unless @sample.key?(kind)
          @sample[kind] = default
          next
        end
        value = @sample.fetch(kind)
        next if finite_numeric?(value) && value.between?(0, 1)

        label = source == :environment ? SAMPLE_ENV_KEYS.fetch(kind) : "config.sample[:#{kind}]"
        invalid_numeric!(label, value, "must be a finite number from 0 through 1", default)
        @sample[kind] = default
      end
    end

    def valid_numeric?(value, rule)
      return true if value.nil? && rule[:allow_nil]
      return false unless finite_numeric?(value)
      return false if rule[:integer] && !value.is_a?(Integer)
      return false if rule[:min] && (rule[:exclusive_min] ? value <= rule[:min] : value < rule[:min])
      return false if rule[:max] && value > rule[:max]

      true
    end

    def finite_numeric?(value)
      value.is_a?(Numeric) && !value.is_a?(Complex) && value.respond_to?(:finite?) && value.finite? &&
        !(value <=> 0).nil?
    rescue StandardError
      false
    end

    def numeric_requirement(rule)
      type = rule[:integer] ? "an integer" : "a finite number"
      lower = if rule[:min]
        rule[:exclusive_min] ? " greater than #{rule[:min]}" : " at least #{rule[:min]}"
      end
      upper = " at most #{rule[:max]}" if rule[:max]
      nullable = " or unset" if rule[:allow_nil]
      "must be #{type}#{lower}#{upper}#{nullable}"
    end

    def invalid_numeric!(label, value, requirement, fallback)
      rendered = value.inspect.to_s.byteslice(0, 100).scrub
      @numeric_errors[label] = "#{label}=#{rendered} #{requirement}; using #{fallback.inspect}"
    end
  end
end
