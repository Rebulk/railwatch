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

        # Sampled-out executions still report unhandled errors (exceptions rate).
        return if exe && !exe.sampled? && (handled || !Sampler.decide(:exceptions))
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
    end
  end
end
