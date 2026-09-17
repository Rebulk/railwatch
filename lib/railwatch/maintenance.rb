# frozen_string_literal: true

module Railwatch
  # The embedded install's own clock. One background thread per web/worker
  # process wakes every TICK seconds and runs whichever maintenance task is
  # due: release-health rollups, threshold and anomaly scans, missed
  # scheduled tasks, auto-resolve, pruning. Every process runs the clock;
  # one process at a time runs a given task, claimed through a lease row in
  # the railwatch database (MaintenanceTask), so a Puma cluster and a Solid
  # Queue worker on the same host do not all prune at once.
  #
  # Same thread shape as Railwatch::Health: parked on a ConditionVariable,
  # started from the engine, re-armed in every forked child. Nothing here
  # goes through Active Job -- the bodies call the job classes' perform
  # directly -- so an embedded install needs no worker, no recurring.yml,
  # and never writes the host's queue adapter.
  #
  # A task must never be visible to the app it is maintaining: each body runs
  # inside Railwatch.ignore and rescues everything.
  module Maintenance
    ROLES = %w[web worker writer].freeze
    TICK = 30
    FOLLOWUP_BATCHES_PER_TICK = 200

    # name => [interval, lease, body]. The lease is how long a claim is held
    # by a process that never releases it (crashed mid-task); it is a ceiling
    # on the work, not an estimate of it.
    TASKS = {
      # A batch's exceptions are grouped into issues right after it commits;
      # a process that dies in between leaves the work recorded on the
      # batch's ledger row. Bounded per tick so a long outage drains over a
      # few ticks rather than one long one.
      "drain_followups" => [ 1.minute, 5.minutes, lambda { |env|
        env.with_telemetry do
          Telemetry::IngestBatch.with_pending_followups.limit(FOLLOWUP_BATCHES_PER_TICK).each do |batch|
            batch.drain_followups!(env)
          end
        end
      } ],
      "release_health" => [ 1.minute, 5.minutes, lambda { |env|
        now = Time.current
        [ now.beginning_of_hour, (now - 1.hour).beginning_of_hour ].each do |bucket|
          ReleaseHealthRollupJob.new.perform(env, bucket)
        end
      } ],
      # Embedded batches fold themselves into the current hour as they land
      # (Ingest::RollupAbsorber), so the reconciler only ever needs to catch
      # rows that arrived after their hour closed.
      "rollup_reconcile" => [ 1.hour, 10.minutes, lambda { |env|
        RollupJob.new.perform(env, (Time.current - 1.hour).beginning_of_hour)
      } ],
      "performance_scan" => [ 5.minutes, 10.minutes, lambda { |env|
        DetectPerformanceIssuesJob.new.perform(env)
      } ],
      "anomaly_scan" => [ 5.minutes, 10.minutes, lambda { |env|
        DetectAnomaliesJob.new.perform(env) if AnomalyRule.where(enabled: true).exists?
      } ],
      "scheduled_tasks" => [ 10.minutes, 10.minutes, lambda { |env|
        CheckScheduledTasksJob.new.perform(env)
      } ],
      "auto_resolve" => [ 24.hours, 10.minutes, lambda { |_env|
        AutoResolveIssuesJob.new.perform
      } ],
      # PASSIVE, not TRUNCATE: this runs inside a Puma worker, and a
      # truncating checkpoint blocks every reader and writer on the file.
      "prune" => [ 24.hours, 60.minutes, lambda { |env|
        PruneTelemetryJob.new.perform(env, checkpoint: "PASSIVE")
        OptimizeTelemetryJob.new.perform(env)
        FollowupReceipt.prune!
      } ]
    }.freeze

    @mutex = Mutex.new
    @wakeup = ConditionVariable.new
    @thread = nil
    @pid = nil
    @stopping = false

    module_function

    # Idempotent; Railwatch.restart_after_fork! calls it again in every forked
    # child.
    def start!
      return unless Railwatch.enabled? && Railwatch.config.local?
      return if defined?(Rails) && Rails.env.test?
      return unless ROLES.include?(Subscribers::ProcessInfo.role)
      # With a writer process listening, it is the one clock. The lease table
      # would keep two clocks honest, but there is no reason to run a second.
      return if !Writer.running? && Writer.listening?
      return if @thread&.alive? && @pid == Process.pid

      @mutex.synchronize do
        return if @thread&.alive? && @pid == Process.pid

        @pid = Process.pid
        @stopping = false
        @thread = Thread.new { run }
        @thread.name = "railwatch-maintenance"
        @thread.abort_on_exception = false
        @thread.report_on_exception = false
      end
    end

    # A forked child inherits a dead thread and may inherit a mutex held by a
    # vanished parent thread; every primitive is replaced before start!.
    def restart_after_fork!
      @mutex = Mutex.new
      @wakeup = ConditionVariable.new
      @thread = nil
      @pid = nil
      @stopping = false
      start!
    end

    def stop!
      return unless @thread

      @stopping = true
      @mutex.synchronize { @wakeup.signal }
      @thread.join(1)
      @thread = nil
    end

    def run
      until @stopping
        @mutex.synchronize { @wakeup.wait(@mutex, TICK) unless @stopping }
        tick unless @stopping
      end
    end

    # Runs every task that is due and unclaimed. Returns the names it ran.
    # Public so a spec, or an operator in a console, can drive the clock by
    # hand. One failing task is reported and does not stop the others.
    #
    # A web worker's clock starts at boot, before the Puma plugin has forked
    # the writer, so the start-time check in start! cannot see it. Checked
    # again on every tick: once a writer is listening this process's clock
    # stands down and stays down (the lease table would keep both honest,
    # but there is no reason to run a second one).
    def tick(now: Time.current)
      return [] if !Writer.running? && Writer.listening?

      ran = []
      Rails.application.executor.wrap do
        env = Environment.current
        TASKS.each do |name, (every, lease, body)|
          token = MaintenanceTask.claim(name, every: every, lease: lease, owner: owner, now: now) or next

          succeeded = false
          begin
            Railwatch.ignore { body.call(env) }
            succeeded = true
            ran << name
          rescue StandardError => e
            # Not Rails.error: this thread has no execution for Railwatch.ignore
            # to pause, so a report there would be captured by Railwatch's own
            # subscriber and opened as an application issue about Railwatch.
            Railwatch.debug { "maintenance #{name} failed: #{e.class}: #{e.message}" }
            Railwatch.notify_unrecoverable(TaskError.new("maintenance task #{name} failed: #{e.class}: #{e.message}"))
          ensure
            MaintenanceTask.release(name, token: token, ran_at: now, succeeded: succeeded)
          end
        end
      end
      ran
    rescue StandardError => e
      # The lease table not being migrated yet is the usual way to get here.
      Railwatch.debug { "maintenance tick failed: #{e.class}: #{e.message}" }
      ran
    end

    def owner
      "#{Railwatch.config.server}:#{Process.pid}"
    end

    class TaskError < StandardError; end
  end
end
