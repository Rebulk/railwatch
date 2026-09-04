# frozen_string_literal: true

module Lantern
  module Subscribers
    # Active Job enqueue and perform, Solid Queue recurring tasks and
    # pruned-process failures. A job attempt is its own execution context,
    # linked to the enqueuing request through JobTracing.
    module Jobs
      extend Base

      module_function

      def install!(_app)
        %w[enqueue enqueue_at enqueue_all].each do |name|
          subscribe("#{name}.active_job") do |event|
            exe = execution
            jobs = name == "enqueue_all" ? Array(event.payload[:jobs]) : [ event.payload[:job] ]
            exe&.count(:jobs_enqueued, jobs.size)
            next unless recording?
            jobs.each do |job|
              Lantern.record(:enqueued_job,
                group: Record.group_hash(job.class.name),
                timestamp: started_at(event),
                job_id: job.job_id,
                name: job.class.name,
                queue: job.queue_name.to_s,
                adapter: adapter_name(event.payload[:adapter]),
                priority: job.priority,
                scheduled_at: job.scheduled_at&.to_f,
                duration: micros(event),
                failed: event.payload[:exception].present? || (job.respond_to?(:successfully_enqueued?) && job.successfully_enqueued? == false))
            end
          end
        end

        subscribe("perform_start.active_job") do |event|
          job = event.payload[:job]
          key, run_at = recurring_task_key(job)
          exe = Lantern.start_execution(
            source: key ? :scheduled_task : :job,
            sample_kind: key ? :scheduled_tasks : :jobs,
            trace_id: job.respond_to?(:lantern_trace_id) ? job.lantern_trace_id : nil,
            parent_id: job.respond_to?(:lantern_parent_id) ? job.lantern_parent_id : nil,
            preview: job.class.name)
          exe.enter_stage(:action)
          # The enqueuing execution's identity, restored from the payload
          # before anything is recorded, so the job_attempt parent and every
          # child record under it carry the same user and tenant as the
          # request that enqueued the job. Local resolution stays the
          # fallback: an older payload, or a job nobody enqueued on a user's
          # behalf, still resolves whatever this process can see. A tenant
          # that was not propagated is left nil so Execution#envelope can
          # still late-bind one the job binds itself (with_tenant).
          propagated_user = job.lantern_user if job.respond_to?(:lantern_user)
          propagated_tenant = job.lantern_tenant if job.respond_to?(:lantern_tenant)
          exe.tenant = propagated_tenant if propagated_tenant
          exe.user_id = propagated_user || Users.resolve_from_current
          exe.queue_latency = queue_latency_micros(job)
          exe.drift = drift_micros(run_at) if key
          job.instance_variable_set(:@__lantern_execution, exe)
          job.instance_variable_set(:@__lantern_recurring_key, key)
        end

        subscribe("perform.active_job") do |event|
          job = event.payload[:job]
          exe = job.instance_variable_get(:@__lantern_execution) or next
          Lantern::Current.execution = exe
          exe.finish_stages
          p = event.payload
          released = job.instance_variable_get(:@__lantern_released)
          status = if released then "released"
          elsif p[:exception_object] then "failed"
          elsif p[:aborted] then "aborted"
          else "processed"
          end
          if p[:exception_object]
            Exceptions.capture(p[:exception_object], handled: false, severity: :error, source: "application.active_job")
          end

          key = job.instance_variable_get(:@__lantern_recurring_key)
          fields = {
            job_id: job.job_id,
            provider_job_id: job.provider_job_id&.to_s,
            attempt_id: exe.id,
            attempt: job.executions,
            name: job.class.name,
            queue: job.queue_name.to_s,
            adapter: adapter_name(p[:adapter]),
            connection: adapter_name(p[:adapter]),
            concurrency_key: job.respond_to?(:concurrency_key) ? job.concurrency_key : nil,
            priority: job.priority,
            status: status,
            queue_latency: exe.queue_latency,
            db_runtime: p[:db_runtime]&.round(2),
            arguments_preview: arguments_preview(job),
            **captured_arguments(job)
          }
          if key
            Lantern.finish_execution(:scheduled_task, group: Record.group_hash(key), task_key: key,
                                     schedule: schedule_for(key), drift: exe.drift, **fields)
          else
            Lantern.finish_execution(:job_attempt, group: Record.group_hash(job.class.name), **fields)
          end
        end

        subscribe("enqueue_retry.active_job") do |event|
          p = event.payload
          # Flag the job so perform.active_job reports "released" instead of
          # "failed" -- the exception was handled internally by retry_on and
          # never escaped perform_now, so this is the only signal we get.
          p[:job]&.instance_variable_set(:@__lantern_released, true)
          next unless recording?
          Lantern.record(:log, level: "warn", message: "Retrying #{p[:job].class.name} in #{p[:wait]}s: #{p[:error]&.class}",
                         tags: [ "active_job", "retry" ], context: "{}")
        end

        subscribe("retry_stopped.active_job") do |event|
          p = event.payload
          Exceptions.capture(p[:error], handled: false, severity: :error, source: "application.active_job.retry_stopped") if p[:error]
        end

        subscribe("discard.active_job") do |event|
          p = event.payload
          Exceptions.capture(p[:error], handled: true, severity: :warning, source: "application.active_job.discard") if p[:error]
        end

        # Solid Queue: jobs whose worker was killed or pruned never fire perform.active_job.
        # Each pruned job gets its own throwaway execution so its job_attempt
        # record carries a fresh execution_id/trace_id instead of borrowing
        # whatever happens to be Current at the time the sweep runs.
        subscribe("fail_many_claimed.solid_queue") do |event|
          p = event.payload
          Array(p[:job_ids]).each do |job_id|
            Lantern::Current.with(Lantern::Execution.new(source: :job, sampled: true)) do
              Lantern.record_now(:job_attempt, group: Record.group_hash("SolidQueue::Pruned"),
                                 job_id: nil, provider_job_id: job_id.to_s, name: "(pruned)", status: "failed",
                                 queue: nil, duration: 0, attempt: nil, stages: {}, counters: {},
                                 exception_preview: p[:error].to_s[0, 255])
            end
          end
        end

        subscribe("enqueue_recurring_task.solid_queue") do |event|
          p = event.payload
          next if p[:skipped]
          Lantern.record(:log, level: p[:enqueue_error] ? "error" : "info",
                         message: "Scheduled #{p[:task]} for #{p[:at]}#{p[:enqueue_error] && ": #{p[:enqueue_error]}"}",
                         tags: [ "solid_queue", "recurring" ], context: JSON.generate(task: p[:task], active_job_id: p[:active_job_id]))
        end
      end

      def adapter_name(adapter)
        adapter.class.name.to_s.demodulize.delete_suffix("Adapter")
      end

      # Measured at perform-start (stored on the execution), not at
      # completion -- otherwise a slow perform inflates its own queue latency.
      def queue_latency_micros(job)
        started = job.scheduled_at || job.enqueued_at
        return nil unless started
        ((Clock.now - started.to_time.utc.to_f) * 1_000_000).round
      rescue StandardError
        nil
      end

      # Difference between the recurring task's scheduled run_at and when
      # this perform actually started, in the same units and at the same
      # point in the lifecycle as queue_latency_micros.
      def drift_micros(run_at)
        return nil unless run_at
        ((Clock.now - run_at.to_f) * 1_000_000).round
      rescue StandardError
        nil
      end

      def arguments_preview(job)
        job.arguments.map { |a| a.respond_to?(:to_global_id) ? a.to_global_id.to_s : a.class.name }.first(10)
      rescue StandardError
        []
      end

      ARGUMENTS_MAX_BYTES = 8 * 1024

      # The job's real arguments, off by default (capture_job_arguments)
      # because they routinely carry PII -- arguments_preview above ships
      # only their shape and is always on.
      #
      # job.serialize["arguments"] is Active Job's own JSON-safe form, so an
      # Active Record argument is already a GlobalID string rather than a
      # hydrated model.
      def captured_arguments(job)
        return {} unless Lantern.config.capture_job_arguments

        kept, truncated = fit_arguments(redact_arguments(job.serialize["arguments"]))
        truncated ? { arguments: kept, arguments_truncated: true } : { arguments: kept }
      rescue StandardError
        {}
      end

      # Hash arguments (including hashes nested in an array argument) go
      # through the same parameter filter as request params, so a
      # `password:` keyword ships as [FILTERED].
      def redact_arguments(arguments)
        Array(arguments).map do |argument|
          case argument
          when Hash then Lantern.redactor.params(argument)
          when Array then redact_arguments(argument)
          else argument
          end
        end
      end

      # Drops trailing arguments until the JSON fits, rather than truncating
      # the JSON itself into something the platform can't parse.
      def fit_arguments(arguments)
        return [ arguments, false ] if JSON.generate(arguments).bytesize <= ARGUMENTS_MAX_BYTES

        kept = arguments.dup
        kept.pop while kept.any? && JSON.generate(kept).bytesize > ARGUMENTS_MAX_BYTES
        [ kept, true ]
      end

      # A job is a scheduled task when Solid Queue recorded a RecurringExecution
      # for it. Cheap lookup by job_id, memoised per job, only when Solid Queue
      # is the adapter and recurring tasks are configured. Returns [task_key,
      # run_at], or nil when there is no matching RecurringExecution.
      def recurring_task_key(job)
        return nil unless defined?(::SolidQueue::RecurringExecution)
        return nil if recurring_keys.empty?
        return [ job.class.name, nil ] if job.is_a?(::SolidQueue::RecurringJob)
        return nil unless recurring_job_classes.include?(job.class.name)
        Lantern.ignore do
          ::SolidQueue::RecurringExecution.joins(:job).where(solid_queue_jobs: { active_job_id: job.job_id }).pick(:task_key, :run_at)
        end
      rescue StandardError
        nil
      end

      # Solid Queue's recurring task table changes when config/recurring.yml
      # is reloaded or dynamic tasks are scheduled, so the lookup tables are
      # re-read every RECURRING_TTL seconds instead of once per process.
      RECURRING_TTL = 60

      def recurring_tasks
        now = Clock.monotonic
        if @recurring_tasks.nil? || now - @recurring_read_at > RECURRING_TTL
          @recurring_tasks = Lantern.ignore { load_recurring_tasks }
          @recurring_read_at = now
        end
        @recurring_tasks
      end

      def load_recurring_tasks
        rows = ::SolidQueue::RecurringTask.pluck(:key, :class_name, :schedule)
        { keys: rows.map(&:first), classes: rows.filter_map { |_k, c, _s| c }.uniq, schedules: rows.to_h { |k, _c, sch| [ k, sch ] } }
      rescue StandardError
        { keys: [], classes: [], schedules: {} }
      end

      def refresh_recurring_tasks!
        @recurring_tasks = nil
      end

      def recurring_keys
        recurring_tasks[:keys]
      end

      def recurring_job_classes
        recurring_tasks[:classes]
      end

      def schedule_for(key)
        recurring_tasks[:schedules][key]
      end
    end
  end
end
