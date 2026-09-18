# frozen_string_literal: true

module Railwatch
  # Recomputes the current and previous hour so rollups are never more than a
  # schedule tick stale, whatever happened to the per-batch RollupJob enqueues
  # (debounced in the web process, and their concurrency semaphore can outlive
  # a worker restart). The platform iterates every active environment; an
  # embedded install has one.
  class RollupCatchupJob < ApplicationJob
    queue_as :rollups

    def perform
      env = Environment.current
      now = Time.current
      [ now.beginning_of_hour, (now - 1.hour).beginning_of_hour ].each do |bucket|
        RollupJob.perform_now(env, bucket)
        ReleaseHealthRollupJob.perform_now(env, bucket)
      end
    end
  end
end
