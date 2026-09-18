# frozen_string_literal: true

require "base64"
require "digest"
require "securerandom"
require "set"
require "uri"
require "zlib"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/isolated_execution_state"
require "active_support/parameter_filter"

require "railwatch/version"
require "railwatch/clock"
require "railwatch/release_detector"
require "railwatch/configuration"
require "railwatch/secret_safety"
require "railwatch/execution"
require "railwatch/current"
require "railwatch/record"
require "railwatch/buffer"
require "railwatch/transport/http"
require "railwatch/transport/local"
require "railwatch/transport/socket"
require "railwatch/writer"
require "railwatch/authentication"
require "railwatch/json_compat"
require "railwatch/embedded"
require "railwatch/ingest_request_body_limit"
require "railwatch/reporter"
require "railwatch/sampler"
require "railwatch/redactor"
require "railwatch/sql_normalizer"
require "railwatch/backtrace"
require "railwatch/context"
require "railwatch/profiler"
require "railwatch/attachments"
# Railwatch::Faraday subclasses ::Faraday::Middleware at load time, so it can't
# be required here: `gemspec` puts this gem in the Gemfile's :default group,
# and Bundler.require(*Rails.groups) requires gems in Gemfile declaration
# order, so railwatch itself is often required *before* an app's own `gem
# "faraday"` line further down the Gemfile. lib/railwatch/engine.rb requires it
# instead, from a Rails initializer, which always runs after Bundler.require
# has finished loading every gem.

# Public API. Mirrors the Laravel Nightwatch facade: user, sample, dontSample,
# ignore, pause, resume, report, redact*, reject*, plus context and deploy.
module Railwatch
  # Monotonic clock reading taken the moment this file loads, i.e. as early in
  # process boot as Railwatch can observe. `process` records measure boot_seconds
  # from here, not from an unset global.
  BOOTED_AT = Clock.monotonic

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
      config
    end

    def reporter
      @reporter ||= Reporter.new(config, transport: local_transport)
    end

    # Embedded mode: a Puma worker hands its batches to the writer process
    # over the socket; the writer itself, and any process when no socket is
    # configured, writes them straight into SQLite. nil means HTTP.
    def local_transport
      return nil unless config.local?
      return Transport::Local.new(config) if Writer.running? || config.writer_socket_path.nil?

      Transport::Socket.new(config)
    end

    def redactor
      @redactor ||= Redactor.new(config)
    end

    def enabled?
      config.enabled?
    end

    # Reset for tests and after reconfiguration.
    def reset!
      @reporter&.shutdown
      @config = nil
      @reporter = nil
      @redactor = nil
    end

    # Runs in every forked child (ActiveSupport::ForkTracker, registered by
    # the engine). The reporter is reset before the child's own process
    # record is written, so nothing inherited from the parent can be flushed
    # alongside it; the health sampler and session flusher restart last, so
    # they emit into the child's reporter, not the parent's.
    def restart_after_fork!
      Profiler.restart_after_fork!
      @reporter&.restart_after_fork!
      Subscribers::Users.restart_after_fork!
      Subscribers::ProcessInfo.restart_after_fork!
      Health.restart_after_fork!
      Sessions.restart_after_fork!
      Maintenance.restart_after_fork!
    end

    # --- execution lifecycle -------------------------------------------------

    def execution
      Current.execution
    end

    def start_execution(source:, sample_kind: source, trace_id: nil, parent_id: nil, preview: nil)
      exe = Execution.new(source: source, sampled: Sampler.decide(sample_kind),
                          trace_id: trace_id, parent_id: parent_id, preview: preview)
      exe.tenant = Context.current_tenant
      # A job (or command) can run inline, nested inside a request's own
      # execution -- e.g. ActiveJob::TestHelper's inline test adapter, or a
      # controller action that calls perform_now. Remembering the execution
      # this one is nested inside lets finish_execution restore it instead of
      # clearing the thread-local outright and losing the outer parent.
      exe.parent_execution = Current.execution
      Current.execution = exe
      # Profiling is off by default, and then this costs one Float
      # comparison per execution: the rest sits behind the short circuit,
      # and tail_buffering? is a bare ivar read the Execution already made.
      start_profile(exe) if config.profile_sample > 0.0 || (exe.tail_buffering? && config.profile_slow_ms)
      exe
    end

    PARENT_TYPES = %i[request job_attempt scheduled_task command channel_action].freeze

    # Ends the execution. A sampled-in execution ships all of its buffered
    # child records plus the parent; a sampled-out one ships only the parent,
    # and only if it raised (so every unhandled exception has a parent) --
    # unless the tail decision (tail_keep?) rescues the whole tree, which is
    # also how a failure-context ring is promoted.
    #
    # The parent's fields may be given as a block instead of keywords. It is
    # called only when a parent is actually going to ship, so a caller whose
    # fields are expensive to assemble (the request middleware: an
    # ActionDispatch::Request, a header walk) skips that work for a
    # head-sampled-out execution nothing rescued.
    def finish_execution(parent_type = nil, group: nil, **fields)
      exe = Current.execution
      return Current.clear unless exe

      exe.capture_memory
      tail = !exe.sampled? && tail_keep?(exe)
      shipping = exe.sampled? || tail
      # The profile is a child record of this execution, so it has to be
      # buffered before the parent is built and the tree is shipped. Stopped
      # either way: a profiler left running would outlive the execution.
      profiled = exe.profiler_handle && ship_profile(exe, shipping)
      parent = nil
      if parent_type && (shipping || exe.exception_sampled)
        fields.merge!(yield) if block_given?
        group ||= fields.delete(:group)
        fields[:tail_sampled] = true if tail
        fields[:profiled] = true if profiled
        parent = build_parent(parent_type, exe, group: group, **fields)
      end
      if shipping
        # Before the records are written: it settles each pending `user`
        # entity's final reference, which a tenant bound after the entity was
        # resolved will have changed.
        Subscribers::Users.commit_execution!(exe) if exe.pending_users
        exe.each_record { |record, bytes| reporter.write(record, bytes) }
        if exe.dropped_records.positive?
          reporter.buffer.account_dropped(exe.dropped_records, bytes: exe.dropped_bytes)
        end
        reporter.write(parent) if parent
      elsif parent
        # Head-sampled out, but an unhandled exception rolled the exceptions
        # sample in: the exception needs its parent, and only its parent.
        reporter.write(parent)
      end
      parent
    ensure
      # Restores the execution this one was nested inside (nil at the
      # outermost level, which behaves the same as the old Current.clear).
      Current.execution = exe&.parent_execution
    end

    # --- record writing --------------------------------------------------------

    # Records that make sense without a parent execution (console, boot).
    # Every other type is dropped when nothing is executing, matching Nightwatch.
    STANDALONE_TYPES = %i[process user visit exception health attachment session].freeze

    # Low-level write for a record hash the caller already built (hot-path
    # subscribers assemble one hash literal instead of packing kwargs, then
    # hand it here). Same enabled/ignored/recording/redact checks as record.
    def push(type, rec)
      return unless enabled?

      exe = Current.execution
      return unless recordable?(type, exe)

      finish(type, rec, exe)
    end

    # Write a child record for the current execution. Silently no-ops when
    # disabled, sampled out, paused, or the type is ignored.
    def record(type, group: nil, timestamp: nil, **fields)
      return unless enabled?

      exe = Current.execution
      return unless recordable?(type, exe)

      finish(type, Record.build(type, exe, group: group, timestamp: timestamp, **fields), exe)
    end

    def build_parent(type, exe, group: nil, **fields)
      rec = Record.build(type, exe, group: group, timestamp: exe.started_at,
                         duration: exe.duration, stages: exe.stage_durations.compact.transform_keys(&:to_s),
                         counters: exe.counters, peak_memory: exe.peak_memory, allocations: exe.allocations,
                         gc_time: exe.gc_time, exception_preview: exe.exception_preview,
                         context: Context.serialized, **fields)
      run_redactors(type, rec)
    end

    def record_now(type, group: nil, **fields)
      return unless enabled?

      rec = Record.build(type, Current.execution, group: group, **fields)
      rec = run_redactors(type, rec) or return
      reporter.write_now(rec)
      rec
    end

    # --- sampling / ignoring ---------------------------------------------------

    def sample(rate = 1.0)
      exe = Current.execution or return
      exe.sampled = rate.to_f >= 1.0 || (rate.to_f > 0.0 && Random.rand < rate.to_f)
    end

    def dont_sample
      Current.execution&.sampled = false
    end

    # Tail sampling: keep this execution (and everything buffered for it)
    # whatever the head decision was. Records made before this call were only
    # buffered if tail sampling was already on for the execution.
    def keep!
      Current.execution&.keep!
    end

    def sampling?
      Current.execution&.sampled? || false
    end

    def ignore
      pause
      yield
    ensure
      resume
    end

    def pause
      Current.execution&.paused_depth += 1
    end

    def resume
      exe = Current.execution
      exe.paused_depth -= 1 if exe && exe.paused_depth.positive?
    end

    def paused?
      Current.execution&.paused? || false
    end

    # --- errors ----------------------------------------------------------------

    def report(error, handled: true, severity: nil, context: {}, attachments: nil, fingerprint: nil)
      rec = Subscribers::Exceptions.capture(error, handled: handled, severity: severity || (handled ? :warning : :error),
                                            context: context, source: "railwatch.manual", fingerprint: fingerprint)
      attachments&.each { |name, data| Attachments.attach(name, data, exception: error) }
      rec
    end

    def attach(...) = Attachments.attach(...)

    # --- context / user --------------------------------------------------------

    def context(**attrs)
      Context.set(**attrs)
    end

    def user(&block)
      config.user(&block)
    end

    def fingerprint(&block)
      config.fingerprint(&block)
    end

    # --- redaction / rejection -------------------------------------------------

    %i[requests queries exceptions cache_events commands mail outgoing_requests logs].each do |type|
      define_method(:"redact_#{type}") { |&blk| config.redactors[type] << blk }
    end

    %i[queries cache_events mail notifications broadcasts outgoing_requests enqueued_jobs logs].each do |type|
      define_method(:"reject_#{type}") { |&blk| config.rejectors[type] << blk }
    end

    def reject_cache_keys(prefixes)
      config.ignored_cache_key_prefixes.concat(Array(prefixes))
    end

    # --- self-monitoring --------------------------------------------------------

    def on_unrecoverable(&block)
      config.on_unrecoverable = block
    end

    # Called (rescued) whenever the gem itself rescues an internal exception:
    # a subscriber block raising, or delivery failing after its retry.
    # Falls back to the debug log when no callback is registered.
    def notify_unrecoverable(error)
      if config.on_unrecoverable
        config.on_unrecoverable.call(error)
      else
        debug { "unrecoverable internal error: #{error.class}: #{error.message}" }
      end
    rescue StandardError => e
      debug { "on_unrecoverable callback raised #{e.class}: #{e.message}" }
    end

    # --- outgoing request helper -------------------------------------------------

    # For HTTP clients without a dedicated patch (e.g. Faraday adapters other
    # than Net::HTTP). Wraps the block, returns its value untouched, and
    # records an outgoing_request child when the result exposes a status.
    def instrument_outgoing(method, url)
      start = Clock.monotonic
      started_at = Clock.now
      result = yield
      if result.respond_to?(:status)
        host = (URI(url.to_s).host rescue nil)
        record(:outgoing_request, group: Record.group_hash(host, method.to_s.upcase),
               timestamp: started_at, host: host, method: method.to_s.upcase,
               url: url.to_s[0, 2048], duration: Clock.micros_since(start), status_code: result.status.to_i)
      end
      result
    end

    # --- custom spans -------------------------------------------------------

    SPAN_MAX_ATTRIBUTES = 25
    SPAN_MAX_VALUE = 200

    # Times an arbitrary block as a `span` child record and returns the
    # block's value. A no-op wrapper (still yields) when Railwatch is disabled
    # or nothing is recording.
    #
    #   Railwatch.span("pdf.render", pages: 12) { renderer.call }
    def span(name, **attributes)
      return yield unless enabled?

      exe = Current.execution
      return yield unless exe&.recording?

      start = Clock.monotonic
      started_at = Clock.now
      status = "failed"
      begin
        result = yield
        status = "ok"
        result
      ensure
        exe.count(:spans)
        record(:span, group: Record.group_hash(name), timestamp: started_at,
               name: name.to_s[0, 255], duration: Clock.micros_since(start),
               attributes: span_attributes(attributes), status: status)
      end
    end

    # --- distributed tracing --------------------------------------------------

    # W3C traceparent for an outgoing request to `host`: nil when propagation
    # is off, no execution is running, or the host isn't on the allow list.
    def traceparent(host)
      return nil unless config.propagate_traces

      exe = Current.execution
      return nil unless exe && propagate_to?(host)

      "00-#{exe.trace_id.delete('-')}-#{exe.id.delete('-')[0, 16]}-#{exe.sampled? ? '01' : '00'}"
    end

    def before_ingest(&block)
      config.before_ingest << block
    end

    def run_before_ingest(batch)
      config.before_ingest.each do |hook|
        result = hook.call(batch)
        return [] if result == false
        batch = result if result.is_a?(Array)
      end
      batch
    end

    # --- misc ------------------------------------------------------------------

    def flush
      reporter.flush
    end

    # Internal diagnostics, only when RAILWATCH_DEBUG=1. Goes to stderr rather
    # than Rails.logger so it can never be captured as an app log record.
    def debug
      return unless config.debug
      warn("[railwatch] #{yield}")
    end

    private

    # Tail decision for a head-sampled-out execution. Only executions that
    # were buffering for the tail can be rescued -- with tail sampling off
    # nothing was buffered, and the exception_sampled path above still ships
    # the lone parent exactly as it did before.
    def tail_keep?(exe)
      return false unless exe.tail_buffering?
      return true if exe.keep
      # A failure-context ring is promoted by one thing only: an unhandled
      # exception this execution actually reported. An execution that
      # completed normally -- or whose exception was ignored, handled,
      # withheld from an interactive runner, raised inside Railwatch.ignore, or
      # lost to the exceptions sample rate -- discards the ring here and
      # ships exactly what it would have shipped without one.
      return exe.exception_reported || false if exe.failure_context?
      return true if exe.exception_sampled

      slow = config.tail_sample_slow_ms
      !slow.nil? && exe.duration >= slow * 1_000
    end

    # Starts the process-global sampling profiler for this execution. Only
    # reached when profiling is configured at all (see start_execution), so
    # loading a backend and rolling the dice stay off the default path.
    def start_profile(exe)
      # An app's test suite inherits its RAILWATCH_* environment, and starting
      # a real profile on every example would make that suite crawl, so in
      # the test env profiling is opt-in through an explicitly non-zero
      # profile_sample -- profile_slow_ms alone is not enough.
      return if config.profile_sample <= 0.0 && defined?(Rails) && Rails.env.test?
      return unless Profiler.available?

      rolled = exe.sampled? && config.profile_sample > 0.0 && Random.rand < config.profile_sample
      # profile_slow_ms can't know an execution is slow until it is over, so
      # it profiles every tail-buffering execution from its first line and
      # throws away the ones that turn out to be fast.
      return unless rolled || (exe.tail_buffering? && config.profile_slow_ms)

      exe.profile_sampled = rolled
      exe.profiler_handle = Profiler.start
    rescue StandardError => e
      debug { "starting profile failed: #{e.class}: #{e.message}" }
      nil
    end

    # Stops this execution's profile -- always, since the backend is
    # process-global and must not be left running -- and buffers it as a
    # `profile` child when the tree ships and the profile is one we asked
    # for: any profile when profile_slow_ms is off, otherwise only a slow
    # execution or one the head profile_sample roll picked. Returns whether
    # a record was buffered, which is what puts `profiled` on the parent.
    def ship_profile(exe, ships)
      profile = Profiler.stop
      return false unless profile && ships

      slow = config.profile_slow_ms
      return false unless slow.nil? || exe.profile_sampled || profile.duration >= slow * 1_000

      collapsed = profile.collapsed
      !record(:profile, timestamp: exe.started_at, profiler: profile.profiler.to_s,
              mode: profile.mode.to_s, interval: profile.interval, duration: profile.duration,
              samples: profile.samples, stacks_bytes: collapsed.bytesize,
              stacks: Base64.strict_encode64(Zlib.gzip(collapsed))).nil?
    rescue StandardError => e
      debug { "shipping profile failed: #{e.class}: #{e.message}" }
      false
    end

    # Same treatment exception locals get: stringified, truncated, capped,
    # and run through the app's parameter filter.
    def span_attributes(attributes)
      return nil if attributes.empty?

      raw = attributes.first(SPAN_MAX_ATTRIBUTES).to_h do |k, v|
        s = v.is_a?(String) ? v : v.inspect
        [ k.to_s, s.length > SPAN_MAX_VALUE ? s[0, SPAN_MAX_VALUE] : s ]
      end
      redactor.params(raw)
    end

    def propagate_to?(host)
      allowed = config.trace_propagation_hosts
      return true if allowed.nil?

      host = host.to_s
      allowed.any? { |h| h.start_with?(".") ? host.end_with?(h) : host == h }
    end

    PLURALS = {
      request: :requests, exception: :exceptions, command: :commands,
      query: :queries, n_plus_one: :queries, transaction: :transactions, cache_event: :cache_events,
      mail: :mail, broadcast: :broadcasts, notification: :notifications, outgoing_request: :outgoing_requests,
      storage_op: :storage_ops, view_render: :view_renders, log: :logs, deprecation: :deprecations,
      session: :sessions, llm_call: :llm_calls
    }.freeze

    def type_plural(type)
      PLURALS.fetch(type, type)
    end

    # Shared by push and record: is this type allowed to be written right now?
    def recordable?(type, exe)
      return false if exe.nil? && !STANDALONE_TYPES.include?(type)
      return false if exe && !exe.recording?
      !config.ignored?(type_plural(type))
    end

    # Shared tail of push and record: redact/reject, then buffer or ship.
    def finish(type, rec, exe)
      unless config.redactors.empty? && config.rejectors.empty?
        rec = run_redactors(type, rec) or return
        return if rejected?(type, rec)
      end

      exe ? exe.buffer(rec) : reporter.write(rec)
      rec
    end

    # config.redactors/rejectors default their Hash on write (Railwatch.redact_*)
    # so a registered type gets its own array; #fetch on read means a type
    # with no hooks never triggers that default proc and allocates one.
    EMPTY_HOOKS = [].freeze

    def run_redactors(type, rec)
      hooks = config.redactors.fetch(type_plural(type), EMPTY_HOOKS)
      return rec if hooks.empty?
      hooks.each { |h| h.call(rec) }
      rec
    rescue StandardError => e
      debug { "redactor for #{type} raised #{e.class}: #{e.message}; dropping record" }
      nil
    end

    def rejected?(type, rec)
      hooks = config.rejectors.fetch(type_plural(type), EMPTY_HOOKS)
      return false if hooks.empty?
      hooks.any? { |h| h.call(rec) }
    rescue StandardError
      false
    end
  end
end

require "railwatch/subscribers"
require "railwatch/dashboard_assets"

module Railwatch
  # Where the engine's two databases migrate from. database.yml names them
  # (`migrations_paths: <%= Railwatch.migrations_path(:railwatch) %>`) so a
  # host's db:prepare creates the tables on install and migrates them after
  # every gem update, from the gem's own history, the way Active Storage
  # migrates its tables. Nothing is copied into the app.
  def self.migrations_path(database)
    File.expand_path("../db/#{database}_migrate", __dir__)
  end

  # Raised when the engine's models are used in an app whose database.yml
  # has no entry for them. They must never fall back to the host's primary
  # connection: the telemetry tables are unprefixed (`sessions`, `visits`,
  # `people`, `notifications`, `logs`), so a query there would read, and a
  # write would corrupt, the application's own tables.
  class DatabaseNotConfigured < StandardError; end
end
require "railwatch/engine" if defined?(Rails::Engine)
