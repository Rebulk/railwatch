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
          scheduled = recurring_task_key(job)
          exe = Lantern.start_execution(
            source: scheduled ? :scheduled_task : :job,
            sample_kind: scheduled ? :scheduled_tasks : :jobs,
            trace_id: job.respond_to?(:lantern_trace_id) ? job.lantern_trace_id : nil,
            parent_id: job.respond_to?(:lantern_parent_id) ? job.lantern_parent_id : nil,
            preview: job.class.name)
          exe.enter_stage(:action)
          exe.user_id = Users.resolve_from_current
          job.instance_variable_set(:@__lantern_execution, exe)
          job.instance_variable_set(:@__lantern_recurring_key, scheduled)
        end

        subscribe("perform.active_job") do |event|
          job = event.payload[:job]
          exe = job.instance_variable_get(:@__lantern_execution) or next
          Lantern::Current.execution = exe
          exe.finish_stages
          p = event.payload
          status = if p[:exception_object] then "failed"
                   elsif p[:aborted] then "aborted"
                   else "processed" end
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
            priority: job.priority,
            status: status,
            queue_latency: queue_latency(job),
            db_runtime: p[:db_runtime]&.round(2),
            arguments_preview: arguments_preview(job)
          }
          if key
            Lantern.finish_execution(:scheduled_task, group: Record.group_hash(key), task_key: key,
                                     schedule: schedule_for(key), **fields)
          else
            Lantern.finish_execution(:job_attempt, group: Record.group_hash(job.class.name), **fields)
          end
        end

        subscribe("enqueue_retry.active_job") do |event|
          next unless recording?
          p = event.payload
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
        subscribe("fail_many_claimed.solid_queue") do |event|
          p = event.payload
          Array(p[:job_ids]).each do |job_id|
            Lantern.record_now(:job_attempt, group: Record.group_hash("SolidQueue::Pruned"),
                               job_id: nil, provider_job_id: job_id.to_s, name: "(pruned)", status: "failed",
                               queue: nil, duration: 0, attempt: nil, stages: {}, counters: {},
                               exception_preview: p[:error].to_s[0, 255])
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

      def queue_latency(job)
        return nil unless job.enqueued_at
        started = job.scheduled_at || job.enqueued_at
        ((Time.now.utc - started.to_time.utc) * 1_000_000).round - 0
      rescue StandardError
        nil
      end

      def arguments_preview(job)
        job.arguments.map { |a| a.respond_to?(:to_global_id) ? a.to_global_id.to_s : a.class.name }.first(10)
      rescue StandardError
        []
      end

      # A job is a scheduled task when Solid Queue recorded a RecurringExecution
      # for it. Cheap lookup by job_id, memoised per job, only when Solid Queue
      # is the adapter and recurring tasks are configured.
      def recurring_task_key(job)
        return nil unless defined?(::SolidQueue::RecurringExecution)
        return nil if recurring_keys.empty?
        return job.class.name if job.is_a?(::SolidQueue::RecurringJob)
        return nil unless recurring_job_classes.include?(job.class.name)
        Lantern.ignore do
          ::SolidQueue::RecurringExecution.joins(:job).where(solid_queue_jobs: { active_job_id: job.job_id }).pick(:task_key)
        end
      rescue StandardError
        nil
      end

      def recurring_keys
        @recurring_keys ||= (::SolidQueue::RecurringTask.pluck(:key) rescue [])
      end

      def recurring_job_classes
        @recurring_job_classes ||= (::SolidQueue::RecurringTask.pluck(:class_name).compact rescue [])
      end

      def schedule_for(key)
        @schedules ||= (::SolidQueue::RecurringTask.pluck(:key, :schedule).to_h rescue {})
        @schedules[key]
      end
    end
  end
end
