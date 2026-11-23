# frozen_string_literal: true

module Railwatch
  module Subscribers
    # Captures Rails.logger lines (via a Logger subclass swap on the broadcast
    # logger) and Rails 8.1 structured events (Rails.event). Level filter
    # comes from config.log_level.
    module Logs
      extend Base

      LEVELS = %w[debug info warn error fatal unknown].freeze
      # Computed once so the hot log record doesn't look this up per call.
      LOG_VERSION = Record::VERSIONS.fetch(:log)
      # Lines Rails itself logs per request/job; the request and job records
      # already carry this information, so they are not stored as logs.
      FRAMEWORK_NOISE = /\A\s*(Started [A-Z]+ "|Processing by |Completed \d{3} |Parameters: \{|Rendered |Rendering |Performing |Performed |Enqueued |\[ActiveJob\]|Cannot render console)/.freeze
      # Literal prefixes for the lines FRAMEWORK_NOISE matches, checked first
      # with cheap start_with? so the regex only runs on lines that could
      # plausibly match, instead of on every captured log line.
      FRAMEWORK_NOISE_PREFIXES = %w[Started Processing Completed Parameters Rendered Rendering Performing Performed Enqueued [ActiveJob] Cannot].freeze

      # Rails 8.1's own structured events (one per request/job phase); the
      # request and job records already carry this information, so they are
      # dropped unless an app opts in via config.capture_framework_events.
      FRAMEWORK_EVENT_PREFIXES = %w[action_controller. action_dispatch. active_job. active_record.
                                    action_view. action_mailer. active_storage. action_cable.].freeze

      class Capture < ::Logger
        # BroadcastLogger#debug? is true when ANY broadcast is at DEBUG, and
        # every framework LogSubscriber (Active Record's SQL line, Action
        # View's render lines, the cache store's) formats its message only
        # when it is. A Logger.new(nil) sits at DEBUG, which made adding
        # Railwatch turn all of that formatting on for lines nobody stored.
        # Starting at config.log_level instead keeps the app's own level in
        # charge. From here on this is an ordinary Logger: `Rails.logger.level
        # =` and `Rails.logger.silence` reach it like any other broadcast, so
        # what the app reads back is what it set.
        def initialize
          super(nil, level: Logs.min_severity)
        end

        def add(severity, message = nil, progname = nil)
          return true unless Railwatch.enabled?
          return true unless Logs.execution
          severity ||= ::Logger::UNKNOWN
          # Both gates: the Logger's own level (which the app may have raised
          # or silenced) and config.log_level (which may have changed since
          # this logger was built).
          return true if severity < level || severity < Logs.min_severity
          message = progname if message.nil? && !block_given?
          message = yield if message.nil? && block_given?
          Logs.write(LEVELS[severity] || "unknown", message)
          true
        end
      end

      class EventSubscriber
        def emit(event)
          return unless Railwatch.enabled?
          name = event[:name].to_s
          return if !Railwatch.config.capture_framework_events && FRAMEWORK_EVENT_PREFIXES.any? { |p| name.start_with?(p) }
          Railwatch.record(:log,
            group: Record.group_hash(name),
            timestamp: event[:timestamp] ? event[:timestamp] / 1_000_000_000.0 : nil,
            level: "event",
            message: name,
            tags: Array(event[:tags]).map(&:to_s),
            context: Logs.event_context(event[:payload]),
            source: event.dig(:source_location, :filepath) && "#{event[:source_location][:filepath].delete_prefix(Backtrace.app_root)}:#{event[:source_location][:lineno]}")
        end
      end

      # Keyed by config.log_level so a level change is picked up on the next
      # log line, but the common case (level unchanged) is one hash lookup
      # instead of a #to_s allocation plus a LEVELS#index scan per line.
      @min_severity_cache = {}

      module_function

      def install!(_app)
        logger = Rails.logger
        if logger.respond_to?(:broadcast_to)
          logger.broadcast_to(Capture.new)
        elsif logger.respond_to?(:extend)
          logger.extend(ActiveSupport::BroadcastLogger) rescue nil
          logger.broadcast_to(Capture.new) if logger.respond_to?(:broadcast_to)
        end
        Rails.event.subscribe(EventSubscriber.new) if Rails.respond_to?(:event)
      end

      def min_severity
        level = Railwatch.config.log_level
        @min_severity_cache[level] ||= (LEVELS.index(level.to_s) || 1)
      end

      # Cheap literal check before the FRAMEWORK_NOISE regex: most log lines
      # share no prefix with the noise patterns, so this skips the regex
      # engine entirely for them.
      def framework_noise?(text)
        text = text.lstrip if text.start_with?(" ", "\t")
        FRAMEWORK_NOISE_PREFIXES.any? { |p| text.start_with?(p) } && text.match?(FRAMEWORK_NOISE)
      end

      def write(level, message)
        exe = execution or return
        text = message.is_a?(String) ? message : message.inspect
        text = text.gsub(/\e\[[\d;]*m/, "") if text.include?("\e")
        return if text.start_with?("[railwatch]") || framework_noise?(text)
        exe.count(:logs)
        return unless recording?
        # Rails' own lines repeat the URLs the request record cleans:
        # "Redirected to <target>", the routing error's quoted path. So
        # does any line an app writes with a URL in it. Cut to twice the
        # stored length first, which bounds the work and still sees the "@"
        # of a userinfo that straddles the final cut.
        text = Railwatch.redactor.filter_text_urls(text[0, 16_384])
        cfg = Railwatch.config
        # One hash literal instead of kwargs-packing into Railwatch.record --
        # every captured Rails.logger line goes through here.
        Railwatch.push(:log, {
          v: LOG_VERSION,
          t: "log",
          timestamp: Clock.now,
          deploy: cfg.deploy,
          server: cfg.server,
          _group: nil,
          **exe.envelope,
          level: level,
          message: text[0, 8192],
          tags: current_tags,
          context: Context.serialized
        })
      end

      # A Rails.event payload as JSON, filtered by key like a span attribute
      # (Redactor#scrub): Rails filters a Hash payload with filter_parameters
      # only, not redact_params or the header rules, and does not filter an
      # event object at all. An event object is read as the Hash of its
      # members (a Struct, a Data) or of its #as_json first, so it is
      # filtered by member name; one that gives no Hash is sent as "{}".
      def event_context(payload)
        redactor = Railwatch.redactor
        unless payload.is_a?(Hash)
          payload = if payload.is_a?(Struct) || (defined?(::Data) && payload.is_a?(::Data))
            payload.to_h
          elsif payload.respond_to?(:as_json)
            payload.as_json
          end
          return "{}" unless payload.is_a?(Hash)
        end
        # Never cut: a cut JSON string cannot be parsed, so an oversized
        # payload is sent as "{}" rather than as half an object.
        json = JSON.generate(redactor.params(redactor.scrub(payload)))
        json.bytesize > 8192 ? "{}" : json
      rescue StandardError
        "{}"
      end

      def current_tags
        logger = Rails.logger
        logger.respond_to?(:current_tags) ? logger.current_tags.map(&:to_s) : []
      rescue StandardError
        []
      end
    end
  end
end
