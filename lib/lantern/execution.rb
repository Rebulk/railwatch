# frozen_string_literal: true

require "securerandom"

module Lantern
  # The parent of every child record: one HTTP request, one job attempt, one
  # scheduled task run, or one command. Holds the sampling decision, the trace
  # id, the current lifecycle stage, and the counters that end up on the parent
  # record. Never touches the database.
  class Execution
    SOURCES = %i[request job scheduled_task command].freeze
    MAX_RECORDS = 10_000
    COUNTERS = %i[queries cached_queries exceptions logs cache_events jobs_enqueued mail
                  broadcasts notifications outgoing_requests storage_ops view_renders
                  transactions hydrated_models lazy_loads deprecations spans].freeze

    attr_reader :source, :id, :trace_id, :parent_id, :started_at, :started_mono, :counters,
                :stages, :stage_durations, :query_groups, :records, :dropped_records, :keep
    attr_accessor :sampled, :exception_preview, :paused_depth,
                  :peak_memory, :allocations_start, :gc_time_start,
                  :queue_latency, :drift, :exception_sampled, :parent_execution
    # Set only when this execution started the process-global sampling
    # profiler (Lantern.start_profile): the backend handle, plus whether the
    # head profile_sample roll -- rather than profile_slow_ms -- is what
    # chose it. Deliberately not initialized in #initialize: with profiling
    # off, which is the default, an execution must not pay two ivar writes
    # for a feature it isn't using.
    attr_accessor :profiler_handle, :profile_sampled
    # Release health, and only written when config.track_sessions is on:
    # the key of the session this request belongs to (Lantern::Sessions),
    # and whether an unhandled exception escaped it. Left uninitialized for
    # the same reason as the profiler pair above.
    attr_accessor :session_key, :session_crashed
    attr_reader :preview, :user_id, :tenant

    def preview=(value)
      @preview = value
      @envelope = nil
    end

    def user_id=(value)
      @user_id = value
      @envelope = nil
    end

    def tenant=(value)
      @tenant = value
      @envelope = nil
    end

    def initialize(source:, sampled:, trace_id: nil, parent_id: nil, preview: nil)
      raise ArgumentError, "unknown source #{source}" unless SOURCES.include?(source)

      @source = source
      @id = SecureRandom.uuid
      @trace_id = trace_id || SecureRandom.uuid
      @parent_id = parent_id
      @sampled = sampled
      @preview = preview
      @started_at = Clock.now
      @started_mono = Clock.monotonic
      @counters = COUNTERS.to_h { |c| [ c, 0 ] }
      @stages = []
      @stage_durations = {}
      @current_stage = nil
      @current_stage_started = @started_mono
      @query_groups = Hash.new(0)
      @paused_depth = 0
      @exception_preview = nil
      @user_id = nil
      @tenant = nil
      @records = []
      @dropped_records = 0
      @keep = false
      # Tail sampling keeps buffering child records for a head-sampled-out
      # execution so the ship/discard decision can be made at the end. Read
      # once here rather than per record: recording? is on the hot path.
      @tail_buffering = !Lantern.config.tail_sample_slow_ms.nil?
      @transaction_statement_counts = Hash.new(0)
      @allocations_start = GC.stat(:total_allocated_objects)
      @gc_time_start = GC.stat(:time) if GC.stat.key?(:time)
    end

    def sampled?
      @sampled
    end

    def paused?
      @paused_depth.positive?
    end

    def recording?
      (sampled? || @tail_buffering) && !paused?
    end

    # Ship this execution's whole tree regardless of the head sampling
    # decision (Lantern.keep!), buffering child records from here on.
    def keep!
      @keep = true
      @tail_buffering = true
    end

    # Whether child records are buffered even when the head decision sampled
    # this execution out, so finish_execution can still decide to ship them.
    def tail_buffering?
      @tail_buffering
    end

    def stage
      @current_stage
    end

    # Close the current stage and open the next. Stage durations are integers
    # in microseconds keyed by stage name, like Nightwatch's request record.
    def enter_stage(name)
      now = Clock.monotonic
      if @current_stage
        @stage_durations[@current_stage] = (@stage_durations[@current_stage] || 0) + ((now - @current_stage_started) * 1_000_000).round
      end
      @current_stage = name
      @current_stage_started = now
      @stages << name
      @envelope = nil
    end

    def finish_stages
      enter_stage(nil)
      @current_stage = nil
    end

    # Child records wait here until the execution ends, so a sampling
    # decision made late (route-level lantern_sample, dont_sample) still
    # applies to everything recorded before it.
    def buffer(record)
      if @records.size >= MAX_RECORDS
        @dropped_records += 1
      else
        @records << record
      end
    end

    # Resident set size in bytes, Linux only. Reading /proc costs ~14µs, so
    # it is sampled at most once per MEMORY_SAMPLE_INTERVAL per process and
    # every execution in between reports the last sample; RSS moves slowly
    # compared with request rates, so the value stays representative.
    MEMORY_SAMPLE_INTERVAL = 1.0
    @memory_sample = nil
    @memory_sampled_at = 0.0

    def self.sampled_memory
      now = Clock.monotonic
      if now - @memory_sampled_at > MEMORY_SAMPLE_INTERVAL
        @memory_sampled_at = now
        @memory_sample = File.read("/proc/self/statm").split(" ", 3)[1].to_i * 4096
      end
      @memory_sample
    rescue StandardError
      @memory_sample
    end

    def capture_memory
      @peak_memory = self.class.sampled_memory
    end

    def count(counter, by = 1)
      @counters[counter] += by
    end

    def track_query_group(group)
      @query_groups[group] += 1
    end

    # Statement counting for the currently-open transaction(s), keyed by the
    # AR transaction object's identity so nested/concurrent transactions on
    # the same execution don't collide. Read once (at transaction end) and
    # discarded, so this never grows across an execution's lifetime.
    def count_transaction_statement(transaction_object_id)
      @transaction_statement_counts[transaction_object_id] += 1
    end

    def transaction_statement_count(transaction_object_id)
      @transaction_statement_counts.delete(transaction_object_id) || 0
    end

    def duration
      Clock.micros_since(@started_mono)
    end

    def allocations
      GC.stat(:total_allocated_objects) - @allocations_start
    end

    def gc_time
      return nil unless @gc_time_start
      GC.stat(:time) - @gc_time_start
    end

    # The envelope every child record shares with its parent. Rebuilt only
    # when a stage, user, tenant, or preview changes; records merge a copy.
    #
    # The app's tenant is usually bound INSIDE the execution -- a middleware
    # nested under Lantern's (activerecord-tenanted's TenantSelector), an
    # around_action, a job's with_tenant block -- so it was nil when the
    # execution opened. While it is still nil, every envelope read asks the
    # app again (two constant checks and a thread-local read) so the first
    # record after the bind, and everything after it including the parent,
    # carries the tenant.
    def envelope
      if @tenant.nil? && (bound = Context.current_tenant)
        @tenant = bound
        @envelope = nil
      end
      @envelope ||= {
        trace_id: @trace_id,
        execution_source: @source.name,
        execution_id: @id,
        parent_id: @parent_id,
        execution_preview: @preview,
        execution_stage: @current_stage&.name,
        user: @user_id,
        tenant: @tenant
      }.freeze
    end
  end
end
