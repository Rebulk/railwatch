# frozen_string_literal: true

# Recomputes the current and previous hour for every active environment so
# late-arriving records land in charts even if the per-batch RollupJob was
# debounced away.
class RollupCatchupJob < ApplicationJob
  queue_as :rollups

  def perform
    now = Time.current.utc.beginning_of_hour
    Environment.active.where("last_seen_at > ?", 2.hours.ago).find_each do |env|
      RollupJob.perform_later(env, now)
      RollupJob.perform_later(env, now - 1.hour)
    end
  end
end
