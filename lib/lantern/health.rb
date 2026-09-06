# frozen_string_literal: true

module Lantern
  # One background thread per web/worker process, shipping a single `health`
  # record every config.health_interval seconds: Puma's thread pool, the
  # Active Record connection pool, and Solid Queue's backlog. Started from the
  # engine's "lantern.health" initializer and re-armed in every forked child
  # from Lantern.restart_after_fork!.
  #
  # A sample must never be visible to the app: the whole thing runs inside
  # Lantern.ignore and rescues everything, so a missing constant, an
  # unmigrated queue database, or a checkout timeout degrades to nil fields
  # rather than raising on a thread nobody is watching.
  module Health
    ROLES = %w[web worker].freeze

    @mutex = Mutex.new
    @wakeup = ConditionVariable.new
    @thread = nil
    @pid = nil
    @stopping = false

    module_function

    # Idempotent; Lantern.restart_after_fork! calls it again in every forked
    # child.
    def start!
      return unless Lantern.enabled?
      return if defined?(Rails) && Rails.env.test?
      return unless ROLES.include?(Subscribers::ProcessInfo.role)
      return if @thread&.alive? && @pid == Process.pid

      @mutex.synchronize do
        return if @thread&.alive? && @pid == Process.pid

        @pid = Process.pid
        @stopping = false
        @thread = Thread.new { run }
        @thread.name = "lantern-health"
        @thread.abort_on_exception = false
        @thread.report_on_exception = false
      end
    end

    # A forked child (Puma cluster worker, Solid Queue forked worker) inherits
    # a dead thread and may inherit a mutex held by a vanished parent thread,
    # so every synchronization primitive must be replaced before start!.
    def restart_after_fork!
      @mutex = Mutex.new
      @wakeup = ConditionVariable.new
      @thread = nil
      @pid = nil
      @stopping = false
      remove_instance_variable(:@puma_server) if defined?(@puma_server)
      start!
    end

    def stop!
      return unless @thread

      @stopping = true
      @mutex.synchronize { @wakeup.signal }
      @thread.join(1)
      @thread = nil
    end

    # Sleeps on a ConditionVariable rather than Kernel#sleep so stop! (from
    # at_exit) wakes the thread immediately instead of waiting out the
    # remainder of the interval. @stopping is re-read while holding the mutex
    # so a stop! that lands just before the wait can't have its signal missed
    # and leave the process hanging for a full interval.
    def run
      until @stopping
        @mutex.synchronize { @wakeup.wait(@mutex, Lantern.config.health_interval) unless @stopping }
        sample unless @stopping
      end
    end

    def sample
      Lantern.ignore do
        puma = puma_stats
        pool = pool_stats
        queue = solid_queue_stats
        Lantern.record(:health,
          pid: Process.pid,
          role: Subscribers::ProcessInfo.role,
          memory: Execution.sampled_memory,
          threads_max: puma[:threads_max],
          threads_busy: puma[:threads_busy],
          backlog: puma[:backlog],
          pool_size: pool[:size],
          pool_busy: pool[:busy],
          pool_waiting: pool[:waiting],
          queue_depth: queue[:queue_depth],
          queue_latency: queue[:queue_latency],
          detail: JSON.generate(
            queues: queue[:queues],
            workers: queue[:workers],
            requests_count: puma[:requests_count],
            running: puma[:running],
            max_threads_reached: puma[:max_threads_reached]))
      end
    rescue StandardError => e
      Lantern.debug { "health sample failed: #{e.class}: #{e.message}" }
      nil
    end

    EMPTY = {}.freeze

    # Puma::Server#stats is the only public API exposing busy_threads, so it is
    # used in preference to the individual readers. It also resets Puma's
    # own since-last-read backlog_max/reactor_max gauges, which Lantern does
    # not report.
    def puma_stats
      server = puma_server or return EMPTY
      s = server.stats
      # Puma's busy_threads counts queued requests too (spawned - waiting +
      # todo), so it can exceed max_threads under load; the pool cannot,
      # and that is what a utilisation percentage should describe.
      {
        threads_max: s[:max_threads],
        threads_busy: s[:busy_threads] && s[:max_threads] ? [ s[:busy_threads], s[:max_threads] ].min : s[:busy_threads],
        backlog: s[:backlog],
        running: s[:running],
        requests_count: s[:requests_count],
        # No idle capacity left in the pool at sample time.
        max_threads_reached: s[:pool_capacity]&.zero?
      }
    rescue StandardError
      EMPTY
    end

    # Looked up once per process: ObjectSpace.each_object walks the whole heap,
    # so it must not run on every sample. Puma constructs its Server while
    # booting, long before the first sample fires.
    def puma_server
      return @puma_server if defined?(@puma_server)
      @puma_server = defined?(::Puma::Server) ? ObjectSpace.each_object(::Puma::Server).first : nil
    rescue StandardError
      @puma_server = nil
    end

    def pool_stats
      ActiveRecord::Base.connection_pool.stat
    rescue StandardError
      EMPTY
    end

    # Read-only counts against the queue database. Solid Queue keeps one row
    # per ready job, so `queue_latency` (the age of the oldest ready job) is
    # the backlog's head-of-line wait, in microseconds.
    def solid_queue_stats
      return EMPTY unless defined?(::SolidQueue)

      oldest = ::SolidQueue::ReadyExecution.minimum(:created_at)
      {
        queue_depth: ::SolidQueue::ReadyExecution.count,
        queue_latency: oldest && ((Clock.now - oldest.to_time.utc.to_f) * 1_000_000).round,
        queues: ::SolidQueue::ReadyExecution.group(:queue_name).count,
        workers: ::SolidQueue::Process.where(kind: "Worker").count
      }
    rescue StandardError
      EMPTY
    end
  end
end
