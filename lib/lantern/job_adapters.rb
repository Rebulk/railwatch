# frozen_string_literal: true

module Lantern
  # Adapter boundary for queue systems that execute jobs without Active Job.
  #
  # An adapter object may implement:
  #
  #   available?                 Whether its optional dependency is loaded.
  #   install!                   Register client/server middleware.
  #   schedule_metadata(payload) Return task_key, schedule, and run_at.
  #   queue_health               Return depth, latency, queues, and workers.
  #
  # Integrations call instrument_enqueue and instrument_perform so direct
  # workers get the same execution, trace, identity, retry, and record
  # semantics as Active Job. Applications can register another adapter from
  # an initializer without adding it as a Lantern dependency.
  module JobAdapters
    CONTEXT_KEY = "_lantern"
    CONTEXT_FIELDS = %w[trace_id parent_id user tenant sampled].freeze
    SCHEDULE_KEY = :lantern_job_adapter_schedule
    ARGUMENTS_MAX_BYTES = 8 * 1024

    @adapters = {}
    @mutex = Mutex.new

    module_function

    def register(name, adapter)
      @mutex.synchronize { @adapters[name.to_sym] = adapter }
      adapter
    end

    def adapters
      # Copy-on-read avoids taking a possibly inherited locked mutex in a
      # forked worker. Registration happens during boot in normal use.
      @adapters.dup
    end

    def install!
      adapters.each_value do |adapter|
        next if adapter.respond_to?(:available?) && !adapter.available?
        adapter.install! if adapter.respond_to?(:install!)
      rescue StandardError => e
        Lantern.debug { "failed to install job adapter #{adapter}: #{e.class}: #{e.message}" }
      end
    end

    # Add only JSON-safe identifier strings and the trace sampling bit. This
    # runs even for a sampled-out execution so a downstream job can retain an
    # adopted upstream trace or make its own sampling decision coherently.
    def inject_context!(payload)
      exe = Lantern.execution
      return payload unless exe

      user = exe.user_id ||= Subscribers::Users.resolve_from_current
      context = payload[CONTEXT_KEY].is_a?(Hash) ? payload[CONTEXT_KEY] : {}
      context = context.merge(
        "trace_id" => exe.trace_id,
        "parent_id" => exe.id,
        "sampled" => exe.sampled?
      )
      context["user"] = user.to_s if user
      tenant = exe.tenant || Context.current_tenant
      context["tenant"] = tenant.to_s if tenant
      payload[CONTEXT_KEY] = context
      payload
    rescue StandardError => e
      Lantern.debug { "job context propagation failed: #{e.class}: #{e.message}" }
      payload
    end

    def extract_context(payload)
      raw = payload[CONTEXT_KEY]
      return {} unless raw.is_a?(Hash)

      raw.slice(*CONTEXT_FIELDS)
    rescue StandardError
      {}
    end

    # A scheduler that calls Active Job or a queue client can mark that
    # enqueue without changing the application's job arguments. The marker is
    # isolated per Rails thread/fiber and serialized by JobTracing or the
    # direct adapter's client middleware.
    def with_schedule(metadata)
      previous = current_schedule
      ActiveSupport::IsolatedExecutionState[SCHEDULE_KEY] = metadata
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[SCHEDULE_KEY] = previous
    end

    def current_schedule
      ActiveSupport::IsolatedExecutionState[SCHEDULE_KEY]
    end

    # Wrap the queue adapter's actual push. The yielded value and any raised
    # exception are passed through unchanged; telemetry is best effort.
    def instrument_enqueue(adapter:, payload:, name:, queue:, job_id:, scheduled_at: nil, priority: nil)
      started = Clock.monotonic
      exe = Lantern.execution
      begin
        inject_context!(payload)
        exe&.count(:jobs_enqueued)
      rescue StandardError => e
        Lantern.debug { "job enqueue setup failed: #{e.class}: #{e.message}" }
      end
      error = nil
      begin
        yield
      rescue Exception => e # preserve queue adapters' non-StandardError failures too
        error = e
        raise
      ensure
        begin
          if exe && Lantern.enabled? && Lantern.execution.equal?(exe)
            Lantern.record(:enqueued_job,
              group: Record.group_hash(name), job_id: job_id, name: name,
              queue: queue.to_s, adapter: adapter.to_s,
              priority: priority, scheduled_at: scheduled_at,
              duration: ((Clock.monotonic - started) * 1_000_000).round,
              failed: !error.nil?)
          end
        rescue StandardError => e
          Lantern.debug { "job enqueue finish failed: #{e.class}: #{e.message}" }
        end
      end
    end

    # Wrap one direct-worker attempt in a Lantern execution. Metadata is a
    # normalized hash supplied by the adapter, which keeps queue-specific
    # payload parsing out of the core lifecycle.
    def instrument_perform(adapter:, payload:, metadata:, schedule: nil)
      schedule ||= schedule_metadata(adapter, payload)
      context = extract_context(payload)
      exe = start_attempt(metadata, context, schedule)
      return yield unless exe

      error = nil
      result = nil
      begin
        result = yield
      rescue Exception => e
        error = e
        raise
      ensure
        finish_attempt(exe, metadata, schedule, error)
      end
      result
    end

    def instrument_scheduled_task(task_key, schedule:, run_at:, adapter:, &block)
      metadata = {
        adapter: adapter.to_s,
        job_id: nil,
        provider_job_id: nil,
        name: task_key.to_s,
        queue: nil,
        priority: nil,
        attempt: 1,
        enqueued_at: nil,
        will_retry: false,
        arguments_preview: []
      }
      instrument_perform(
        adapter: adapter.to_sym,
        payload: {},
        metadata: metadata,
        schedule: { task_key: task_key.to_s, schedule: schedule, run_at: run_at },
        &block)
    end

    def schedule_metadata(adapter, payload)
      integration = adapters[adapter.to_sym]
      return unless integration&.respond_to?(:schedule_metadata)
      integration.schedule_metadata(payload)
    rescue StandardError => e
      Lantern.debug { "job schedule metadata failed: #{e.class}: #{e.message}" }
      nil
    end

    # Merge queue systems rather than choosing whichever constant happened to
    # load first. Single-adapter queue names stay backward compatible; when
    # several systems report, names are qualified to avoid collisions.
    def queue_health
      reports = adapters.filter_map do |name, adapter|
        next if adapter.respond_to?(:available?) && !adapter.available?
        next if adapter.respond_to?(:health_active?) && !adapter.health_active?
        next unless adapter.respond_to?(:queue_health)
        stats = adapter.queue_health
        [ name, stats ] if stats && !stats.empty?
      rescue StandardError => e
        Lantern.debug { "job adapter health failed for #{name}: #{e.class}: #{e.message}" }
        nil
      end
      return {} if reports.empty?

      qualify = reports.length > 1
      {
        queue_depth: reports.sum { |_name, s| s[:queue_depth].to_i },
        queue_latency: reports.filter_map { |_name, s| s[:queue_latency] }.max,
        queues: reports.each_with_object({}) do |(name, stats), all|
          stats.fetch(:queues, {}).each { |queue, count| all[qualify ? "#{name}:#{queue}" : queue.to_s] = count }
        end,
        workers: reports.sum { |_name, s| s[:workers].to_i },
        adapters: reports.to_h { |name, _s| [ name.to_s, true ] }
      }
    end

    def start_attempt(metadata, context, schedule)
      exe = nil
      source = schedule ? :scheduled_task : :job
      exe = Lantern.start_execution(
        source: source,
        sample_kind: schedule ? :scheduled_tasks : :jobs,
        trace_id: context["trace_id"],
        parent_id: context["parent_id"],
        preview: metadata[:name])
      if context["sampled"] == true
        exe.sampled = true
        exe.keep! # also expands any sampled-out failure-context ring
      end
      exe.tenant = context["tenant"] if context["tenant"]
      exe.user_id = context["user"] || Subscribers::Users.resolve_from_current
      exe.queue_latency = latency_micros(metadata[:enqueued_at])
      exe.drift = latency_micros(schedule[:run_at]) if schedule
      exe.enter_stage(:action)
      exe
    rescue StandardError => e
      Lantern.debug { "job attempt start failed: #{e.class}: #{e.message}" }
      Current.execution = exe.parent_execution if exe && Current.execution.equal?(exe)
      nil
    end

    def finish_attempt(exe, metadata, schedule, error)
      Current.execution = exe
      exe.finish_stages
      if error && !metadata[:requeued]
        Subscribers::Exceptions.capture(error, handled: false, severity: :error,
          source: "application.#{metadata[:adapter]}")
      end
      fields = metadata.slice(:job_id, :provider_job_id, :name, :queue, :priority, :arguments_preview)
      fields.merge!(metadata.slice(:arguments, :arguments_truncated))
      fields.merge!(
        attempt_id: exe.id,
        attempt: metadata[:attempt],
        adapter: metadata[:adapter],
        connection: metadata[:adapter],
        status: attempt_status(metadata, error),
        queue_latency: exe.queue_latency)
      if schedule
        Lantern.finish_execution(:scheduled_task, group: Record.group_hash(schedule[:task_key]),
          task_key: schedule[:task_key], schedule: schedule[:schedule], drift: exe.drift, **fields)
      else
        Lantern.finish_execution(:job_attempt, group: Record.group_hash(metadata[:name]), **fields)
      end
    rescue StandardError => e
      Lantern.debug { "job attempt finish failed: #{e.class}: #{e.message}" }
      Current.execution = exe.parent_execution if Current.execution.equal?(exe)
    end

    def attempt_status(metadata, error)
      return "processed" unless error
      return "released" if metadata[:requeued]
      metadata[:will_retry] ? "released" : "failed"
    end

    def latency_micros(value)
      return unless value
      time = value.respond_to?(:to_time) ? value.to_time.to_f : Float(value)
      ((Clock.now - time) * 1_000_000).round
    rescue StandardError
      nil
    end

    def captured_arguments(arguments)
      return {} unless Lantern.config.capture_job_arguments

      kept = redact_arguments(Array(arguments))
      return { arguments: kept } if JSON.generate(kept).bytesize <= ARGUMENTS_MAX_BYTES

      kept.pop while kept.any? && JSON.generate(kept).bytesize > ARGUMENTS_MAX_BYTES
      { arguments: kept, arguments_truncated: true }
    rescue StandardError
      {}
    end

    def redact_arguments(value)
      case value
      when Hash then Lantern.redactor.params(value.transform_values { |child| redact_arguments(child) })
      when Array then value.map { |child| redact_arguments(child) }
      else value
      end
    end
  end
end
