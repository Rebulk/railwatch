# frozen_string_literal: true

module Lantern
  # All settings, each overridable by a LANTERN_* env var. Mirrors the shape of
  # Laravel Nightwatch's config so the two products document the same knobs.
  class Configuration
    RECORD_TYPES = %i[queries cache_events mail broadcasts notifications outgoing_requests
                      storage_ops view_renders logs transactions deprecations].freeze

    attr_accessor :enabled, :token, :ingest_url, :deploy, :server, :environment,
                  :sample, :ignore, :log_level, :capture_request_payload,
                  :capture_exception_source, :redact_headers, :redact_params,
                  :buffer_size, :flush_interval, :flush_threshold,
                  :connect_timeout, :timeout, :shutdown_timeout,
                  :slow_query_threshold_ms, :n_plus_one_threshold,
                  :max_view_renders_per_execution, :ignored_cache_key_prefixes,
                  :beacon_enabled, :debug

    attr_reader :user_resolver, :redactors, :rejectors, :before_ingest

    def initialize
      @enabled = env_bool("LANTERN_ENABLED", true)
      @token = ENV["LANTERN_TOKEN"]
      @ingest_url = ENV.fetch("LANTERN_INGEST_URL", "https://lantern.rebulk.com")
      @deploy = ENV["LANTERN_DEPLOY"] || ENV["KAMAL_VERSION"] || ENV["GIT_REV"]
      @server = ENV["LANTERN_SERVER"] || Socket.gethostname
      @environment = nil # resolved lazily from Rails.env
      @sample = {
        requests: env_float("LANTERN_REQUEST_SAMPLE_RATE", 1.0),
        jobs: env_float("LANTERN_JOB_SAMPLE_RATE", 1.0),
        commands: env_float("LANTERN_COMMAND_SAMPLE_RATE", 1.0),
        scheduled_tasks: env_float("LANTERN_SCHEDULED_TASK_SAMPLE_RATE", 1.0),
        exceptions: env_float("LANTERN_EXCEPTION_SAMPLE_RATE", 1.0)
      }
      @ignore = RECORD_TYPES.select { |t| env_bool("LANTERN_IGNORE_#{t.to_s.upcase}", false) }
      @log_level = (ENV["LANTERN_LOG_LEVEL"] || "info").to_sym
      @capture_request_payload = env_bool("LANTERN_CAPTURE_REQUEST_PAYLOAD", false)
      @capture_exception_source = env_bool("LANTERN_CAPTURE_EXCEPTION_SOURCE_CODE", true)
      @redact_headers = ENV.fetch("LANTERN_REDACT_HEADERS", "Authorization,Cookie,Set-Cookie,Proxy-Authorization,X-CSRF-Token,X-XSRF-TOKEN").split(",").map(&:strip)
      @redact_params = ENV.fetch("LANTERN_REDACT_PARAMS", "password,password_confirmation,authenticity_token,_token").split(",").map(&:strip)
      @buffer_size = env_int("LANTERN_BUFFER_SIZE", 5_000)
      @flush_interval = env_float("LANTERN_FLUSH_INTERVAL", 2.0)
      @flush_threshold = env_int("LANTERN_FLUSH_THRESHOLD", 500)
      @connect_timeout = env_float("LANTERN_CONNECT_TIMEOUT", 1.0)
      @timeout = env_float("LANTERN_TIMEOUT", 3.0)
      @shutdown_timeout = env_float("LANTERN_SHUTDOWN_TIMEOUT", 2.0)
      @slow_query_threshold_ms = env_float("LANTERN_SLOW_QUERY_MS", 5.0)
      @n_plus_one_threshold = env_int("LANTERN_N_PLUS_ONE_THRESHOLD", 5)
      @max_view_renders_per_execution = 20
      @ignored_cache_key_prefixes = %w[rack::attack flipper/ solid_cable]
      @beacon_enabled = env_bool("LANTERN_BEACON", true)
      @debug = env_bool("LANTERN_DEBUG", false)
      @user_resolver = nil
      @redactors = Hash.new { |h, k| h[k] = [] }
      @rejectors = Hash.new { |h, k| h[k] = [] }
      @before_ingest = []
    end

    def user(&block)
      @user_resolver = block
    end

    def enabled?
      @enabled && token.present?
    end

    def ignored?(type)
      @ignore.include?(type)
    end

    def sample_rate(kind)
      @sample.fetch(kind, 1.0).to_f.clamp(0.0, 1.0)
    end

    def environment_name
      @environment || (defined?(Rails) ? Rails.env.to_s : "production")
    end

    private

    def env_bool(key, default)
      return default unless ENV.key?(key)
      %w[1 true yes on].include?(ENV[key].to_s.downcase)
    end

    def env_float(key, default)
      ENV.key?(key) ? ENV[key].to_f : default
    end

    def env_int(key, default)
      ENV.key?(key) ? ENV[key].to_i : default
    end
  end
end
