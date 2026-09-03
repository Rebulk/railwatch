# frozen_string_literal: true

module Lantern
  module Subscribers
    # Captures Rails.logger lines (via a Logger subclass swap on the broadcast
    # logger) and Rails 8.1 structured events (Rails.event). Level filter
    # comes from config.log_level.
    module Logs
      extend Base

      LEVELS = %w[debug info warn error fatal unknown].freeze
      # Lines Rails itself logs per request/job; the request and job records
      # already carry this information, so they are not stored as logs.
      FRAMEWORK_NOISE = /\A\s*(Started [A-Z]+ "|Processing by |Completed \d{3} |Parameters: \{|Rendered |Rendering |Performing |Performed |Enqueued |\[ActiveJob\]|Cannot render console)/.freeze

      class Capture < ::Logger
        def initialize
          super(nil)
        end

        def add(severity, message = nil, progname = nil)
          return true unless Lantern.enabled?
          severity ||= ::Logger::UNKNOWN
          return true if severity < Logs.min_severity
          message = progname if message.nil? && !block_given?
          message = yield if message.nil? && block_given?
          Logs.write(LEVELS[severity] || "unknown", message)
          true
        end
      end

      class EventSubscriber
        def emit(event)
          return unless Lantern.enabled?
          Lantern.record(:log,
            group: Record.group_hash(event[:name]),
            timestamp: event[:timestamp] ? event[:timestamp] / 1_000_000_000.0 : nil,
            level: "event",
            message: event[:name].to_s,
            tags: Array(event[:tags]).map(&:to_s),
            context: (JSON.generate(event[:payload]) rescue "{}")[0, 8192],
            source: event.dig(:source_location, :filepath) && "#{event[:source_location][:filepath].delete_prefix(Backtrace.app_root)}:#{event[:source_location][:lineno]}")
        end
      end

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
        LEVELS.index(Lantern.config.log_level.to_s) || 1
      end

      def write(level, message)
        exe = execution or return
        text = message.is_a?(String) ? message : message.inspect
        text = text.gsub(/\e\[[\d;]*m/, "")
        return if text.start_with?("[lantern]") || text.match?(FRAMEWORK_NOISE)
        exe.count(:logs)
        return unless recording?
        Lantern.record(:log,
          level: level,
          message: text[0, 8192],
          tags: current_tags,
          context: Context.serialized)
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
