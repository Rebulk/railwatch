# frozen_string_literal: true

require "digest"
require "set"
require "uri"
require "active_support"
require "active_support/core_ext/object/blank"
require "active_support/isolated_execution_state"
require "active_support/parameter_filter"

require "lantern/version"
require "lantern/clock"
require "lantern/configuration"
require "lantern/execution"
require "lantern/current"
require "lantern/record"
require "lantern/buffer"
require "lantern/transport/http"
require "lantern/reporter"
require "lantern/sampler"
require "lantern/redactor"
require "lantern/sql_normalizer"
require "lantern/backtrace"
require "lantern/context"
# Faraday::Middleware doesn't exist unless the host app depends on Faraday,
# and Lantern::Faraday subclasses it at load time -- so this only loads when
# Faraday is already available (Bundler.require runs before an app's own
# `require "lantern"`, so this is reliable in the normal boot order).
require "lantern/faraday" if defined?(::Faraday)

# Public API. Mirrors the Laravel Nightwatch facade: user, sample, dontSample,
# ignore, pause, resume, report, redact*, reject*, plus context and deploy.
module Lantern
  # Monotonic clock reading taken the moment this file loads, i.e. as early in
  # process boot as Lantern can observe. `process` records measure boot_seconds
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
      @reporter ||= Reporter.new(config)
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
      exe
    end

    PARENT_TYPES = %i[request job_attempt scheduled_task command].freeze

    # Ends the execution. A sampled-in execution ships all of its buffered
    # child records plus the parent; a sampled-out one ships only the parent,
    # and only if it raised (so every unhandled exception has a parent).
    def finish_execution(parent_type = nil, group: nil, **fields)
      exe = Current.execution
      return Current.clear unless exe

      exe.capture_memory
      parent = parent_type && build_parent(parent_type, exe, group: group, **fields)
      if exe.sampled?
        exe.records.each { |r| reporter.write(r) }
        reporter.buffer.instance_variable_set(:@dropped, reporter.buffer.dropped + exe.dropped_records) if exe.dropped_records.positive?
        reporter.write(parent) if parent
      elsif parent && exe.exception_sampled
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
    STANDALONE_TYPES = %i[process user visit exception].freeze

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

    def report(error, handled: true, severity: nil, context: {})
      Subscribers::Exceptions.capture(error, handled: handled, severity: severity || (handled ? :warning : :error),
                                      context: context, source: "lantern.manual")
    end

    # --- context / user --------------------------------------------------------

    def context(**attrs)
      Context.set(**attrs)
    end

    def user(&block)
      config.user(&block)
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

    # Internal diagnostics, only when LANTERN_DEBUG=1. Goes to stderr rather
    # than Rails.logger so it can never be captured as an app log record.
    def debug
      return unless config.debug
      warn("[lantern] #{yield}")
    end

    private

    PLURALS = {
      query: :queries, n_plus_one: :queries, transaction: :transactions, cache_event: :cache_events,
      mail: :mail, broadcast: :broadcasts, notification: :notifications, outgoing_request: :outgoing_requests,
      storage_op: :storage_ops, view_render: :view_renders, log: :logs, deprecation: :deprecations
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

    # config.redactors/rejectors default their Hash on write (Lantern.redact_*)
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

require "lantern/subscribers"
require "lantern/engine" if defined?(Rails::Engine)
