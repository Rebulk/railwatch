# frozen_string_literal: true

module Lantern
  module JobAdapters
    module Sidekiq
      DEFAULT_RETRIES = 25

      module CronEnqueueHook
        def enqueue!(time = Time.now.utc)
          task_name = respond_to?(:name) ? name : instance_variable_get(:@name)
          task_namespace = respond_to?(:namespace) ? namespace : instance_variable_get(:@namespace)
          task_key = [ task_namespace, task_name ].compact.reject { |part| part.to_s.empty? || part.to_s == "default" }.join(":")
          task_schedule = respond_to?(:cron) ? cron : instance_variable_get(:@cron)
          JobAdapters.with_schedule(task_key: task_key, schedule: task_schedule, run_at: time) { super }
        end
      end

      class ClientMiddleware
        def call(job_class, payload, queue, _redis_pool = nil, &block)
          return block.call unless Sidekiq.direct?(payload)

          Sidekiq.activate!
          if (schedule = JobAdapters.current_schedule)
            payload[CONTEXT_KEY] = (payload[CONTEXT_KEY].is_a?(Hash) ? payload[CONTEXT_KEY] : {}).merge(
              "task_key" => schedule[:task_key].to_s, "schedule" => schedule[:schedule]&.to_s,
              "run_at" => schedule[:run_at]&.to_f)
          end
          JobAdapters.instrument_enqueue(
            adapter: "Sidekiq", payload: payload,
            name: Sidekiq.job_name(job_class, payload), queue: queue,
            job_id: payload["jid"], scheduled_at: payload["at"],
            priority: nil, &block)
        end
      end

      class ServerMiddleware
        def call(_instance, payload, queue, &block)
          return block.call unless Sidekiq.direct?(payload)

          Sidekiq.activate!
          JobAdapters.instrument_perform(
            adapter: :sidekiq, payload: payload,
            metadata: Sidekiq.perform_metadata(payload, queue), &block)
        end
      end

      module_function

      def available?
        defined?(::Sidekiq) && ::Sidekiq.respond_to?(:configure_client)
      end

      def install!
        return if @installed

        ::Sidekiq.configure_client { |config| add_client_middleware(config) }
        ::Sidekiq.configure_server do |config|
          add_client_middleware(config)
          config.server_middleware { |chain| chain.add(ServerMiddleware) }
          install_cron_hook!
        end
        install_cron_hook!
        @installed = true
      end

      # Loading the optional gem alone must not make every Rails process poll
      # Redis. Direct use activates health sampling on first enqueue/perform;
      # an Active Job Sidekiq adapter or a Sidekiq server is active at boot.
      def health_active?
        @used || (::Sidekiq.respond_to?(:server?) && ::Sidekiq.server?) ||
          (defined?(::ActiveJob::Base) && ::ActiveJob::Base.queue_adapter_name.to_s == "sidekiq")
      rescue StandardError
        false
      end

      def activate!
        @used = true
      end

      def install_cron_hook!
        return unless defined?(::Sidekiq::Cron::Job)
        return if ::Sidekiq::Cron::Job < CronEnqueueHook

        ::Sidekiq::Cron::Job.prepend(CronEnqueueHook)
      end

      def add_client_middleware(config)
        config.client_middleware { |chain| chain.add(ClientMiddleware) }
      end

      # Active Job's Sidekiq wrapper already emits active_job notifications;
      # observing it here too would create duplicate parents and child records.
      def direct?(payload)
        payload.is_a?(Hash) && !payload.key?("wrapped") &&
          payload["class"] != "ActiveJob::QueueAdapters::SidekiqAdapter::JobWrapper"
      end

      def job_name(job_class, payload)
        (payload["display_class"] || payload["class"] || (job_class.respond_to?(:name) && job_class.name) || job_class).to_s
      end

      def perform_metadata(payload, queue)
        retries = payload.fetch("retry", true)
        retry_count = Integer(payload.fetch("retry_count", -1))
        retry_limit = retries.is_a?(Integer) ? retries : default_retries
        {
          adapter: "Sidekiq",
          job_id: payload["jid"],
          provider_job_id: payload["jid"],
          name: job_name(payload["class"], payload),
          queue: queue.to_s,
          attempt: retry_count + 2,
          enqueued_at: timestamp_seconds(payload["enqueued_at"]),
          # Sidekiq increments retry_count after server middleware unwinds,
          # then exhausts when that new count reaches the configured limit.
          will_retry: retry_remaining?(payload, retries, retry_count, retry_limit),
          arguments_preview: Array(payload["args"]).first(10).map { |argument| argument.class.name },
          **JobAdapters.captured_arguments(payload["args"])
        }
      rescue StandardError
        {
          adapter: "Sidekiq", job_id: payload["jid"], provider_job_id: payload["jid"],
          name: job_name(payload["class"], payload), queue: queue.to_s,
          attempt: nil, enqueued_at: payload["enqueued_at"], will_retry: false,
          arguments_preview: []
        }
      end

      def default_retries
        value = ::Sidekiq.default_configuration[:max_retries] if available?
        value.is_a?(Integer) ? value : DEFAULT_RETRIES
      rescue StandardError
        DEFAULT_RETRIES
      end

      def retry_remaining?(payload, retries, retry_count, retry_limit)
        return false if retries == false

        retry_for = payload["retry_for"]
        failed_at = payload["failed_at"]
        if retry_for
          duration = Float(retry_for)
          return false unless duration.positive?
          return true unless failed_at

          # Sidekiq treats retry_for as duration-exclusive: unlike ordinary
          # retries it ignores the configured attempt ceiling. Sidekiq 8
          # stores failed_at as integer milliseconds; Sidekiq 7 and legacy
          # payloads use floating-point seconds.
          return timestamp_seconds(failed_at) + duration >= Clock.now
        end

        (retry_count + 1) < retry_limit
      rescue StandardError
        false
      end

      def timestamp_seconds(value)
        return if value.nil?
        return value.to_time.to_f if value.respond_to?(:to_time)

        value.is_a?(Integer) ? value / 1_000.0 : Float(value)
      rescue StandardError
        nil
      end

      # The sidekiq-cron enqueue hook writes these identifiers into the job
      # payload. Resolve legacy/external cron identifiers too when present.
      def schedule_metadata(payload)
        key = payload.dig(CONTEXT_KEY, "task_key") || payload["cron_job_id"]
        return unless key

        schedule = payload.dig(CONTEXT_KEY, "schedule")
        if schedule.nil? && defined?(::Sidekiq::Cron::Job)
          namespace = payload["cron_namespace"]
          job = ::Sidekiq::Cron::Job.find(key, namespace)
          schedule = job&.cron
        end
        run_at = payload.dig(CONTEXT_KEY, "run_at") || payload["at"] || payload["enqueued_at"]
        {
          task_key: key.to_s,
          schedule: schedule,
          run_at: timestamp_seconds(run_at)
        }
      rescue StandardError
        { task_key: key.to_s, schedule: nil,
          run_at: timestamp_seconds(payload["at"] || payload["enqueued_at"]) }
      end

      def queue_health
        require "sidekiq/api" unless defined?(::Sidekiq::Queue)
        queues = ::Sidekiq::Queue.all
        {
          queue_depth: queues.sum(&:size),
          queue_latency: queues.empty? ? nil : (queues.map(&:latency).max.to_f * 1_000_000).round,
          queues: queues.to_h { |queue| [ queue.name, queue.size ] },
          workers: ::Sidekiq::ProcessSet.new.size
        }
      rescue LoadError, StandardError
        {}
      end
    end

    register(:sidekiq, Sidekiq)
  end
end
