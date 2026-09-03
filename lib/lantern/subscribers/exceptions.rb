# frozen_string_literal: true

module Lantern
  module Subscribers
    # Everything that flows through Rails.error (handled and unhandled, with
    # severity, source, and context) plus what the Rack middleware catches.
    # Unhandled exceptions are shipped immediately so a crashing process still
    # reports; that also makes them survive sampled-out executions.
    module Exceptions
      extend Base

      class ErrorSubscriber
        def report(error, handled:, severity:, context:, source: nil)
          Exceptions.capture(error, handled: handled, severity: severity, context: context, source: source)
        end
      end

      module_function

      def install!(_app)
        Rails.error.subscribe(ErrorSubscriber.new) if defined?(Rails) && Rails.respond_to?(:error)
      end

      def capture(error, handled:, severity:, context: {}, source: nil)
        return unless Lantern.enabled?
        return if seen?(error)

        exe = execution
        exe&.count(:exceptions)
        exe.exception_preview ||= "#{error.class}: #{error.message}"[0, 255] if exe

        # Sampled-out executions still report an unhandled error, governed by
        # the exceptions sample rate. Decided once per execution and memoized,
        # so a burst of errors doesn't re-roll the dice each time.
        return if exe && !exe.sampled? && (handled || !exception_sampled?(exe))
        return if exe&.paused?

        cause = error.cause
        frames = Backtrace.frames(error, with_source: Lantern.config.capture_exception_source)
        top = frames.find { |f| f[:in_app] } || frames.first || {}
        rec = {
          class: error.class.name,
          message: error.message.to_s[0, 4096],
          handled: handled,
          severity: severity.to_s,
          source: source.to_s,
          file: top[:file],
          line: top[:line],
          frames: frames,
          cause: cause && { class: cause.class.name, message: cause.message.to_s[0, 1024] },
          context: Context.serialized_with(context),
          code: error_code(error),
          sql_state: sql_state_for(error),
          ruby_version: RUBY_VERSION,
          rails_version: (Rails.version rescue nil)
        }
        group = Record.group_hash(error.class.name, top[:file], top[:line], normalize_message(error.message))
        if handled
          Lantern.record(:exception, group: group, **rec)
        else
          Lantern.record_now(:exception, group: group, **rec)
        end
      end

      def seen?(error)
        return true if error.instance_variable_get(:@__lantern_seen)
        error.instance_variable_set(:@__lantern_seen, true)
        false
      rescue StandardError
        false
      end

      def normalize_message(message)
        message.to_s.gsub(/\b\d+\b/, "?").gsub(/0x[0-9a-f]+/i, "0x?")[0, 200]
      end

      # Decided once per execution and memoized on exception_sampled, so the
      # sampling roll happens exactly once even across many exceptions.
      def exception_sampled?(exe)
        return exe.exception_sampled unless exe.exception_sampled.nil?
        exe.exception_sampled = Sampler.decide(:exceptions)
      end

      # errno-style code: SystemCallError subclasses (Errno::ECONNREFUSED etc)
      # define an Errno class constant; some drivers expose #errno or #code.
      def error_code(error)
        if error.class.const_defined?(:Errno)
          error.class.const_get(:Errno)
        elsif error.respond_to?(:errno)
          error.errno
        elsif error.respond_to?(:code)
          error.code
        end
      rescue StandardError
        nil
      end

      # Database SQLSTATE for ActiveRecord::StatementInvalid, when the
      # underlying driver error exposes one (e.g. pg; sqlite3 does not).
      def sql_state_for(error)
        return nil unless defined?(ActiveRecord::StatementInvalid) && error.is_a?(ActiveRecord::StatementInvalid)
        cause = error.cause
        cause.respond_to?(:sql_state) ? cause.sql_state : nil
      rescue StandardError
        nil
      end
    end
  end
end
