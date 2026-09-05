# frozen_string_literal: true

module Lantern
  module JobAdapters
    module SolidQueue
      module_function

      def available?
        defined?(::SolidQueue::ReadyExecution)
      end

      def queue_health
        oldest = ::SolidQueue::ReadyExecution.minimum(:created_at)
        {
          queue_depth: ::SolidQueue::ReadyExecution.count,
          queue_latency: JobAdapters.latency_micros(oldest),
          queues: ::SolidQueue::ReadyExecution.group(:queue_name).count,
          workers: ::SolidQueue::Process.where(kind: "Worker").count
        }
      rescue StandardError
        {}
      end
    end

    register(:solid_queue, SolidQueue)
  end
end
