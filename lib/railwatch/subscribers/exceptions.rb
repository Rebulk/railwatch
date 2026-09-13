# frozen_string_literal: true

module Railwatch
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
        Locals.install! if Railwatch.config.capture_exception_locals

        # An exception a controller swallows with `rescue_from` never reaches
        # Rails.error or the middleware, so without this it is invisible.
        # Rails instruments the moment a matching handler is found, which is
        # exactly Sentry's report_rescued_exceptions. Active Job's equivalents
        # (retry_on / discard_on) are already covered by the
        # retry_stopped/discard subscriptions in Subscribers::Jobs.
        subscribe("rescue_from_callback.action_controller") do |event|
          next unless Railwatch.config.capture_rescued_exceptions
          capture(event.payload[:exception], handled: true, severity: :warning,
                  source: "action_controller.rescue_from")
        end
      end

      # Local variables at the raise site, like Sentry's "locals" panel.
      # Opt-in (RAILWATCH_CAPTURE_EXCEPTION_LOCALS): a TracePoint on :raise
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
            next if error.instance_variable_defined?(:@__railwatch_locals)
            error.instance_variable_set(:@__railwatch_locals, snapshot(tp.binding))
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
          Railwatch.redactor.params(raw)
        end

        def inspect_value(value)
          s = value.inspect
          s.length > MAX_VALUE ? s[0, MAX_VALUE] + "…" : s
        rescue StandardError
          "#<#{value.class}>"
        end

        def for(error)
          error.instance_variable_get(:@__railwatch_locals)
        rescue StandardError
          nil
        end
      end

      def capture(error, handled:, severity:, context: {}, source: nil, fingerprint: nil)
        return unless Railwatch.enabled?
        return if ignored?(error)

        exe = execution
        if exe&.first_exception_observation?(error, handled)
          exe.count(:exceptions)
          exe.exception_preview ||= "#{error.class}: #{error.message}"[0, 255]
        end
        # An interactive `rails runner` -- typed, piped, or a script in /tmp --
        # is an engineer at a shell, and their typo is not an issue. Their
        # command record still ships, carrying the exit code and the preview
        # set just above, so the run is visible without opening one. Checked
        # here rather than only where the patch rescues because the Rails
        # executor reports the error to Rails.error first (source
        # "application.runner.railties"), inside the runner's own call.
        return if exe&.interactive
        # Release health: an unhandled exception ends this request's session
        # crashed. Flagged rather than written straight into the session map
        # because the key is only resolved once the request finishes (a
        # user-keyed session has no cookie to read up front).
        exe.session_crashed = true if exe && !handled && Railwatch.config.track_sessions

        # Sampled-out executions still report an unhandled error, governed by
        # the exceptions sample rate. Decided once per execution and memoized,
        # so a burst of errors doesn't re-roll the dice each time.
        return if exe && !exe.sampled? && (handled || !exception_sampled?(exe))
        return if exe&.paused?
        return if exe && !exe.first_exception_report?(error, handled)

        cause = error.cause
        frames = Backtrace.frames(error, with_source: Railwatch.config.capture_exception_source)
        top = top_frame(frames)
        parts, fingerprint_source = fingerprint_for(error, top, override: fingerprint)
        # So an attachment filed against this same error object later
        # (Railwatch.attach(exception:)) lands on the issue this call chose.
        remember_fingerprint(error, parts) if fingerprint
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
          locals: Railwatch.config.capture_exception_locals ? Locals.for(error) : nil,
          fingerprint: parts,
          fingerprint_source: fingerprint_source,
          ruby_version: RUBY_VERSION,
          rails_version: (Rails.version rescue nil)
        }
        group = Record.group_hash(*parts)
        if handled
          Railwatch.record(:exception, group: group, **rec)
        else
          # The one signal that promotes a failure-context ring, set here --
          # where the exception is actually written -- rather than where the
          # exceptions sample was rolled above, so an exception dropped on
          # the way to this line never ships a sampled-out execution's
          # children (Railwatch.tail_keep?).
          exe.exception_reported = true if exe
          Railwatch.record_now(:exception, group: group, **rec)
        end
      end

      # The group hash `capture` would assign this error. Public so
      # Railwatch.attach can file an attachment against the same issue without
      # having to re-derive the bucketing rule (source snippets are skipped:
      # they cost I/O and don't take part in the hash).
      def group_for(error)
        parts = error.instance_variable_get(:@__railwatch_fingerprint) ||
                fingerprint_for(error, top_frame(Backtrace.frames(error, with_source: false))).first
        Record.group_hash(*parts)
      end

      # The frame an occurrence is filed under: the first application frame,
      # falling back to the top of the backtrace for an error raised entirely
      # inside a gem.
      def top_frame(frames)
        frames.find { |f| f[:in_app] } || frames.first || {}
      end

      MAX_FINGERPRINT_PARTS = 10
      MAX_FINGERPRINT_PART = 200

      # The parts this occurrence is hashed on, and where they came from:
      # an explicit `Railwatch.report(error, fingerprint: [...])` ("report"),
      # the error object's own #railwatch_fingerprint ("error"), the
      # `Railwatch.fingerprint { }` resolver ("resolver"), or Railwatch's own
      # class/frame/message parts ("default"). Anything that comes back
      # empty -- or raises -- falls back to the default, so a bad resolver
      # can never lose an exception.
      def fingerprint_for(error, top, override: nil)
        default = default_fingerprint(error, top)
        custom, source =
          if override then [ override, "report" ]
          elsif error.respond_to?(:railwatch_fingerprint) then [ error.railwatch_fingerprint, "error" ]
          elsif (resolver = Railwatch.config.fingerprint_resolver) then [ resolver.call(error, default), "resolver" ]
          end
        parts = custom && expand_fingerprint(custom, default)
        parts ? [ parts, source ] : [ cap_fingerprint(default), "default" ]
      rescue StandardError => e
        Railwatch.debug { "fingerprint for #{error.class} raised #{e.class}: #{e.message}; using the default" }
        [ cap_fingerprint(default || [ error.class.name ]), "default" ]
      end

      def default_fingerprint(error, top)
        [ error.class.name, top[:file], top[:line], normalize_message(message_key(error)) ]
      end

      # A custom fingerprint: `:default` splices in the parts Railwatch would
      # have used (Sentry's "{{ default }}"), everything else is stringified.
      # nil when nothing usable is left, so the caller can fall back.
      def expand_fingerprint(custom, default)
        parts = Array(custom).flat_map { |part| part == :default ? default : part }
        parts = cap_fingerprint(parts.reject { |part| part.nil? || part.to_s.empty? })
        parts.empty? ? nil : parts
      end

      def cap_fingerprint(parts)
        parts.first(MAX_FINGERPRINT_PARTS).map { |part| part.to_s[0, MAX_FINGERPRINT_PART] }
      end

      def remember_fingerprint(error, parts)
        error.instance_variable_set(:@__railwatch_fingerprint, parts)
      rescue StandardError
        nil
      end

      # config.ignored_exceptions, matched against the error's own class name
      # and every named ancestor, so an app's subclass of an ignored error is
      # ignored too. Sentry's excluded_exceptions equivalent, and it applies to
      # handled and unhandled errors alike.
      def ignored?(error)
        ignored = Railwatch.config.ignored_exceptions
        return false if ignored.empty?
        error.class.ancestors.any? { |ancestor| (name = ancestor.name) && ignored.include?(name) }
      end

      # Variable data that would otherwise split one issue into thousands of
      # them. Applied in this order: a URL before the numbers inside it, a
      # quoted string before the id it quotes, hex before plain digits.
      MESSAGE_NOISE = [
        %r{\bhttps?://\S+},                                  # URLs
        /\b[^\s@]+@[^\s@]+\.[^\s@]+\b/,                      # email addresses
        /\h{8}-\h{4}-\h{4}-\h{4}-\h{12}/,                    # UUIDs
        /\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}\S*/,         # ISO timestamps
        /\b\d{1,3}(?:\.\d{1,3}){3}\b/,                       # IPv4 addresses
        /(?<!\w)'[^']*'|"[^"]*"/,                             # quoted strings ("won't" is not one)
        /\b(?:0x)?\h{6,}\b/,                                 # hex: digests, object addresses
        /\b\d+\b/                                            # plain integers
      ].freeze

      # After the rules above every value in a SQL bind list is "?", so
      # collapse "(?, ?, ?)" to "(?)": an IN (...) groups the same at any length.
      BIND_LIST = /\(\s*\?(?:\s*,\s*\?)*\s*\)/

      # Classes whose message is mostly the data that varied -- the record
      # that wasn't found, the key that was missing, the receiver that had no
      # method. For those the default key keeps only the message prefix, up
      # to the first ":" (or " for ", for the NameError family), and lets the
      # class and the frame do the rest of the bucketing. Matched on the
      # exact class name, so an app's own subclass keeps its whole message.
      MESSAGE_PREFIXES = {
        "ActiveRecord::RecordNotFound" => ":", "ActiveRecord::RecordInvalid" => ":",
        "KeyError" => ":", "ArgumentError" => ":", "TypeError" => ":",
        "NoMethodError" => " for ", "NameError" => " for "
      }.freeze

      def normalize_message(message)
        text = MESSAGE_NOISE.inject(message.to_s) { |m, pattern| m.gsub(pattern, "?") }
        text.gsub(BIND_LIST, "(?)").gsub(/\s+/, " ").strip[0, 200]
      end

      def message_key(error)
        message = error.message.to_s
        separator = MESSAGE_PREFIXES[error.class.name] or return message
        message.split(separator, 2).first.to_s
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
