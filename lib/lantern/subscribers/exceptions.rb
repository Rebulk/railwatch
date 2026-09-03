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
        Locals.install! if Lantern.config.capture_exception_locals

        # An exception a controller swallows with `rescue_from` never reaches
        # Rails.error or the middleware, so without this it is invisible.
        # Rails instruments the moment a matching handler is found, which is
        # exactly Sentry's report_rescued_exceptions. Active Job's equivalents
        # (retry_on / discard_on) are already covered by the
        # retry_stopped/discard subscriptions in Subscribers::Jobs.
        subscribe("rescue_from_callback.action_controller") do |event|
          next unless Lantern.config.capture_rescued_exceptions
          capture(event.payload[:exception], handled: true, severity: :warning,
                  source: "action_controller.rescue_from")
        end
      end

      # Local variables at the raise site, like Sentry's "locals" panel.
      # Opt-in (LANTERN_CAPTURE_EXCEPTION_LOCALS): a TracePoint on :raise
      # snapshots the raising frame's binding onto the exception object,
      # already stringified, truncated, and run through the param filter so
      # a `password` local ships as [FILTERED]. Costs one binding walk per
      # raise, nothing on the happy path.
      module Locals
        MAX_LOCALS = 25
        MAX_VALUE = 200

        module_function

        def install!
          return if @trace
          @trace = TracePoint.new(:raise) do |tp|
            error = tp.raised_exception
            next if error.instance_variable_defined?(:@__lantern_locals)
            error.instance_variable_set(:@__lantern_locals, snapshot(tp.binding))
          rescue StandardError
            nil
          end
          @trace.enable
        end

        def uninstall!
          @trace&.disable
          @trace = nil
        end

        def snapshot(binding)
          return nil unless binding
          names = binding.local_variables.first(MAX_LOCALS)
          raw = names.to_h { |n| [ n.to_s, inspect_value(binding.local_variable_get(n)) ] }
          Lantern.redactor.params(raw)
        end

        def inspect_value(value)
          s = value.inspect
          s.length > MAX_VALUE ? s[0, MAX_VALUE] + "…" : s
        rescue StandardError
          "#<#{value.class}>"
        end

        def for(error)
          error.instance_variable_get(:@__lantern_locals)
        rescue StandardError
          nil
        end
      end

      def capture(error, handled:, severity:, context: {}, source: nil)
        return unless Lantern.enabled?
        return if ignored?(error)
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
        top = top_frame(frames)
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
          locals: Lantern.config.capture_exception_locals ? Locals.for(error) : nil,
          ruby_version: RUBY_VERSION,
          rails_version: (Rails.version rescue nil)
        }
        group = group_from(error, top)
        if handled
          Lantern.record(:exception, group: group, **rec)
        else
          Lantern.record_now(:exception, group: group, **rec)
        end
      end

      # The group hash `capture` would assign this error. Public so
      # Lantern.attach can file an attachment against the same issue without
      # having to re-derive the bucketing rule (source snippets are skipped:
      # they cost I/O and don't take part in the hash).
      def group_for(error)
        group_from(error, top_frame(Backtrace.frames(error, with_source: false)))
      end

      # The frame an occurrence is filed under: the first application frame,
      # falling back to the top of the backtrace for an error raised entirely
      # inside a gem.
      def top_frame(frames)
        frames.find { |f| f[:in_app] } || frames.first || {}
      end

      def group_from(error, top)
        Record.group_hash(error.class.name, top[:file], top[:line], normalize_message(error.message))
      end

      # config.ignored_exceptions, matched against the error's own class name
      # and every named ancestor, so an app's subclass of an ignored error is
      # ignored too. Sentry's excluded_exceptions equivalent, and it applies to
      # handled and unhandled errors alike.
      def ignored?(error)
        ignored = Lantern.config.ignored_exceptions
        return false if ignored.empty?
        error.class.ancestors.any? { |ancestor| (name = ancestor.name) && ignored.include?(name) }
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
