# frozen_string_literal: true

module Railwatch
  # Recomputes one hourly release_health bucket from raw `sessions` rows.
  # Idempotent, and debounced by the same Solid Queue concurrency control
  # RollupJob uses: while one recompute of a bucket is queued or running,
  # further enqueues for it are discarded rather than piling up.
  #
  # The gem re-sends a live session every flush interval, so the same
  # session_id lands in a bucket many times. Each id collapses to the worst
  # status it reached (crashed beats errored beats ok beats started) and its
  # longest reported duration, which is what makes "sessions" a session count
  # rather than a record count.
  class ReleaseHealthRollupJob < ApplicationJob
    queue_as :rollups
    limits_concurrency to: 1, key: ->(environment, bucket) { "release_health:#{environment.id}:#{bucket.to_i}" }, duration: 10.minutes, on_conflict: :discard

    RANKS = { "started" => 0, "ok" => 1, "errored" => 2, "crashed" => 3 }.freeze
    CRASHED = RANKS["crashed"]
    ERRORED = RANKS["errored"]

    def perform(environment, bucket)
      bucket = bucket.utc.beginning_of_hour
      # PruneTelemetryJob deletes raw sessions in whole hours below this floor.
      # A rollup enqueued before the prune can run after it, and rebuilding a
      # pruned hour would replace a complete aggregate with an empty one.
      return if bucket < environment.retention_days.days.ago.utc.beginning_of_hour

      environment.with_telemetry do
        rows = Telemetry::Session.where(occurred_at: bucket...(bucket + 1.hour))
          .where.not(deploy: nil).pluck(:deploy, :session_id, :status, :duration, :user_ref)
        aggregates = rows.group_by(&:first).map { |deploy, group| aggregate(deploy, bucket, collapse(group)) }
        Telemetry::ReleaseHealth.transaction do
          Telemetry::ReleaseHealth.where(bucket: bucket).delete_all
          Telemetry::ReleaseHealth.insert_all(aggregates) if aggregates.any?
        end
      end
    end

    private

    # session_id => the worst status, longest duration, and first user seen for
    # it in this bucket.
    def collapse(rows)
      rows.each_with_object({}) do |(_deploy, session_id, status, duration, user_ref), sessions|
        session = sessions[session_id] ||= { rank: 0, duration: nil, user: nil }
        session[:rank] = [ session[:rank], RANKS.fetch(status.to_s, 0) ].max
        session[:duration] = [ session[:duration] || 0, duration ].max if duration
        session[:user] ||= user_ref
      end
    end

    def aggregate(deploy, bucket, sessions)
      durations = sessions.values.filter_map { |s| s[:duration] }
      users = sessions.values.filter_map { |s| s[:user] }.uniq
      crashed_users = sessions.values.select { |s| s[:rank] == CRASHED }.filter_map { |s| s[:user] }.uniq
      { deploy: deploy, bucket: bucket, sessions: sessions.size,
       sessions_errored: sessions.values.count { |s| s[:rank] == ERRORED },
       sessions_crashed: sessions.values.count { |s| s[:rank] == CRASHED },
       users: users.size, users_crashed: crashed_users.size,
       duration_sum: durations.sum, duration_count: durations.size }
    end
  end
end
