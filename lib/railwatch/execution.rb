# frozen_string_literal: true

require "securerandom"

module Railwatch
  # The parent of every child record: one HTTP request, one job attempt, one
  # scheduled task run, one command, or one Action Cable channel action. Holds
  # the sampling decision, the trace id, the current lifecycle stage, and the
  # counters that end up on the parent record. Never touches the database.
  class Execution
    SOURCES = %i[request job scheduled_task command channel_action].freeze
    MAX_RECORDS = 10_000
    COUNTERS = %i[queries cached_queries exceptions logs cache_events jobs_enqueued mail
                  broadcasts notifications outgoing_requests storage_ops view_renders
                  transactions hydrated_models lazy_loads deprecations spans llm_calls].freeze
    # GC.stat with no key builds the whole stat hash; whether this Ruby
    # reports GC time never changes, so ask once.
    GC_TIME_SUPPORTED = GC.stat.key?(:time)

    attr_reader :source, :id, :trace_id, :parent_id, :started_at, :started_mono, :counters,
                :stages, :stage_durations, :query_groups, :records, :dropped_records,
                :dropped_bytes, :buffered_bytes, :keep
    attr_accessor :sampled, :exception_preview, :paused_depth,
                  :peak_memory, :allocations_start, :gc_time_start,
                  :queue_latency, :drift, :exception_sampled, :parent_execution
    # Set by Subscribers::Exceptions.capture at the moment it actually writes
    # an unhandled exception for this execution -- not when it rolls the
    # exceptions sample -- so it is the one signal that promotes a
    # failure-context ring. Left uninitialized (nil) like the pairs below:
    # an execution that never fails must not pay a write for one that does.
    attr_accessor :exception_reported
    # Set only when this execution started the process-global sampling
    # profiler (Railwatch.start_profile): the backend handle, plus whether the
    # head profile_sample roll -- rather than profile_slow_ms -- is what
    # chose it. Deliberately not initialized in #initialize: with profiling
    # off, which is the default, an execution must not pay two ivar writes
    # for a feature it isn't using.
    attr_accessor :profiler_handle, :profile_sampled
    # Release health, and only written when config.track_sessions is on:
    # the key of the session this request belongs to (Railwatch::Sessions),
    # and whether an unhandled exception escaped it. Left uninitialized for
    # the same reason as the profiler pair above.
    attr_accessor :session_key, :session_crashed
    # Set only by Railwatch::Patches::RunnerCommand, for a `rails runner` an
    # engineer typed or piped: the execution is still recorded, but its
    # exceptions are a shell session's, not the application's, so nothing
    # reports them (Subscribers::Exceptions.capture). Left uninitialized like
    # the pairs above -- a request must not pay an ivar write for this.
    attr_accessor :interactive
    # Set only by Subscribers::Users, and only for a user this process has
    # not emitted an entity for this hour: the cache key(s) and the `user`
    # record object(s) buffered for them, held until finish_execution says
    # whether this tree actually shipped. Left uninitialized like the pairs
    # above -- the common case (a user already seen this hour, or none at
    # all) must not pay an ivar write.
    attr_accessor :pending_users
    attr_reader :preview, :user_id, :user_raw_id, :tenant

    # One rule for turning a resolved user id into the reference that goes on
    # a record. Already-qualified references (a job payload's, or one built
    # while the tenant was known) pass through unchanged.
    def self.qualified_user(raw_id, tenant)
      return raw_id if raw_id.nil? || tenant.nil? || raw_id.start_with?("#{tenant}:")

      "#{tenant}:#{raw_id}"
    end

    def preview=(value)
      @preview = value
      @envelope = nil
    end

    # The raw id is kept because the tenant may not be bound yet: an app that
    # resolves its user in a before_action and its tenant in the next one
    # would otherwise emit "1" for every tenant's user 1.
    def user_id=(value)
      @user_raw_id = value&.to_s
      @user_id = Execution.qualified_user(@user_raw_id, @tenant)
      @envelope = nil
    end

    def tenant=(value)
      previous_user = @user_id
      @tenant = value
      @user_id = Execution.qualified_user(@user_raw_id, @tenant)
      requalify_buffered_records(previous_user) if value && @user_id != previous_user
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
      @user_raw_id = nil
      @tenant = nil
      @records = []
      @record_bytes = []
      @buffered_bytes = 0
      @dropped_records = 0
      @dropped_bytes = 0
      @keep = false
      # Tail sampling keeps buffering child records for a head-sampled-out
      # execution so the ship/discard decision can be made at the end. Read
      # once here rather than per record: recording? is on the hot path.
      @tail_buffering = !Railwatch.config.tail_sample_slow_ms.nil?
      # Failure context is the same mechanism on a shorter leash: with tail
      # sampling off, a head-sampled-out execution still buffers its last
      # config.failure_context child records in a ring, and only an unhandled
      # exception promotes them (Railwatch.tail_keep?). Skipped when tail
      # sampling is already buffering everything -- the larger buffer wins --
      # and when the head kept this execution, which buffers everything
      # anyway. Off by default, so a sampled-out execution stays as cheap as
      # it has always been.
      @failure_context = !sampled && !@tail_buffering && Railwatch.config.failure_context.positive?
      @tail_buffering ||= @failure_context
      @record_limit = @failure_context ? Railwatch.config.failure_context : MAX_RECORDS
      @byte_limit = Railwatch.config.execution_buffer_bytes
      @transaction_statement_counts = Hash.new(0)
      @allocations_start = GC.stat(:total_allocated_objects)
      @gc_time_start = GC.stat(:time) if GC_TIME_SUPPORTED
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
    # decision (Railwatch.keep!), buffering child records from here on.
    def keep!
      @keep = true
      @tail_buffering = true
      # Whatever the ring already dropped is gone, but a kept execution ships
      # its whole tree, so from here on it buffers like any other.
      @failure_context = false
      @record_limit = MAX_RECORDS
    end

    # Whether child records are buffered even when the head decision sampled
    # this execution out, so finish_execution can still decide to ship them.
    def tail_buffering?
      @tail_buffering
    end

    # Whether that buffer is a failure-context ring (bounded, promoted only
    # by an unhandled exception) rather than a full tail-sampling buffer.
    def failure_context?
      @failure_context
    end

    # A tenant that binds after records were already buffered leaves them
    # attributed to an unqualified user and to no tenant at all. Rewriting
    # them here is a single pass over a buffer that is usually a handful of
    # records, and it happens at most once per execution -- the guard in
    # #tenant= only fires when the reference actually changed.
    def requalify_buffered_records(previous_user)
      @records.each do |record|
        record[:user] = @user_id if record[:user] == previous_user
        record[:tenant] = @tenant if record[:tenant].nil?
      end
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
    # decision made late (route-level railwatch_sample, dont_sample) still
    # applies to everything recorded before it.
    def buffer(record)
      bytes = Record.buffered_bytes(record, limit: @byte_limit)
      # A record heavier than the whole per-execution budget can only be
      # dropped: making room for it would mean discarding the entire tree and
      # still not fitting.
      if bytes > @byte_limit
        @dropped_records += 1
        @dropped_bytes += bytes
        return
      end

      # A failure-context ring keeps the LAST record_limit records: the ones
      # just before the exception are the ones worth having. Every other
      # buffer keeps the earliest and rejects the overflow. Either way the
      # loss is counted onto the parent's batch (Railwatch.finish_execution).
      if @failure_context
        drop_oldest while @records.any? && (@records.size >= @record_limit || @buffered_bytes + bytes > @byte_limit)
      elsif @records.size >= @record_limit || @buffered_bytes + bytes > @byte_limit
        @dropped_records += 1
        @dropped_bytes += bytes
        return
      end

      @records << record
      @record_bytes << bytes
      @buffered_bytes += bytes
    end

    # The tree, with each record's already-measured weight, so the reporter
    # queue does not weigh them a second time.
    def each_record
      @records.each_with_index { |record, index| yield record, @record_bytes[index] }
    end

    def drop_oldest
      @records.shift
      bytes = @record_bytes.shift
      @buffered_bytes -= bytes
      @dropped_records += 1
      @dropped_bytes += bytes
    end
    private :drop_oldest

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

    # The counters that actually fired. Most executions touch a handful of the
    # 18, so sending the rest as explicit zeros costs roughly 240 bytes on the
    # wire and in storage, per execution, to say nothing happened. A reader
    # treats an absent counter as zero, exactly as it treats a zero.
    def counted
      @counters.reject { |_, value| value.zero? }
    end

    # Rails.error and an outer middleware can observe the same error. Count
    # that occurrence once even when sampling or pause prevents its report.
    # Reporting has separate flags so a suppressed observation can still be
    # captured after those gates change.
    def first_exception_observation?(error, handled)
      mark_exception(error, handled ? 1 : 2)
    end

    def first_exception_report?(error, handled)
      mark_exception(error, handled ? 4 : 8)
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
    # nested under Railwatch's (activerecord-tenanted's TenantSelector), an
    # around_action, a job's with_tenant block -- so it was nil when the
    # execution opened. While it is still nil, every envelope read asks the
    # app again (two constant checks and a thread-local read) so the first
    # record after the bind, and everything after it including the parent,
    # carries the tenant.
    def envelope
      if @tenant.nil? && (bound = Context.current_tenant)
        self.tenant = bound
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

    private

    # Exception deduplication belongs to an execution, not to the Exception
    # object. Weak identity keys avoid retaining every reported error for the
    # full lifetime of a long-running execution, and the map is allocated on
    # the first exception so an execution that never sees one pays nothing.
    def mark_exception(error, flag)
      states = (@exception_states ||= ObjectSpace::WeakMap.new)
      state = states[error].to_i
      return false if state.anybits?(flag)

      states[error] = state | flag
      true
    rescue StandardError
      # Telemetry must never interfere with the application. If an unusual
      # exception cannot be used as a weak key, fail open and report it.
      true
    end
  end
end
