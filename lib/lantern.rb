# frozen_string_literal: true

require "digest"
require "set"
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

# Public API. Mirrors the Laravel Nightwatch facade: user, sample, dontSample,
# ignore, pause, resume, report, redact*, reject*, plus context and deploy.
module Lantern
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
      elsif parent && exe.counters[:exceptions].positive?
        reporter.write(parent)
      end
      parent
    ensure
      Current.clear
    end

    # --- record writing --------------------------------------------------------

    # Records that make sense without a parent execution (console, boot).
    # Every other type is dropped when nothing is executing, matching Nightwatch.
    STANDALONE_TYPES = %i[process user visit exception].freeze

    # Write a child record for the current execution. Silently no-ops when
    # disabled, sampled out, paused, or the type is ignored.
    def record(type, group: nil, timestamp: nil, **fields)
      return unless enabled?

      exe = Current.execution
      return if exe.nil? && !STANDALONE_TYPES.include?(type)
      return if exe && !exe.recording?
      return if config.ignored?(type_plural(type))

      rec = Record.build(type, exe, group: group, timestamp: timestamp, **fields)
      rec = run_redactors(type, rec) or return
      return if rejected?(type, rec)

      exe ? exe.buffer(rec) : reporter.write(rec)
      rec
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

    def run_redactors(type, rec)
      hooks = config.redactors[type_plural(type)]
      return rec if hooks.empty?
      hooks.each { |h| h.call(rec) }
      rec
    rescue StandardError => e
      debug { "redactor for #{type} raised #{e.class}: #{e.message}; dropping record" }
      nil
    end

    def rejected?(type, rec)
      hooks = config.rejectors[type_plural(type)]
      return false if hooks.empty?
      hooks.any? { |h| h.call(rec) }
    rescue StandardError
      false
    end
  end
end

require "lantern/subscribers"
require "lantern/engine" if defined?(Rails::Engine)
