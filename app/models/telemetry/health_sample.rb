# frozen_string_literal: true

module Telemetry
  # Periodic Puma / Solid Queue health sample from one process: thread pool
  # utilisation, socket backlog, connection pool pressure, queue depth and
  # the age of the oldest ready job.
  class HealthSample < TelemetryRecord
    # The gem reports every 15s, so a process that has not sampled in ten
    # minutes is gone rather than idle.
    LIVE_WINDOW = 10.minutes
    BUCKET = 5.minutes

    scope :recent, -> { order(sampled_at: :desc) }
    scope :between, ->(from, to) { where(sampled_at: from..to) }

    # The newest sample from each (server, pid) pair seen since `time`: one
    # row per process still reporting.
    def self.live(time = LIVE_WINDOW.ago)
      where(id: where(sampled_at: time..).group(:server, :pid).select(Arel.sql("MAX(id)"))).order(:server, :pid)
    end

    # Health over the window, one point per BUCKET: thread utilisation is a
    # percentage averaged across the processes that sampled into the bucket,
    # backlog is summed across them, and the queue figures are the worst
    # seen (any process's reading covers the whole queue).
    def self.series(from, to, bucket: BUCKET)
      slice = bucket_expression(bucket)
      between(from, to).group(slice).order(slice)
        .pluck(slice,
               Arel.sql("AVG(CASE WHEN threads_max > 0 THEN threads_busy * 100.0 / threads_max END)"),
               Arel.sql("SUM(backlog)"), Arel.sql("MAX(queue_depth)"), Arel.sql("MAX(queue_latency)"))
        .map do |t, utilisation, backlog, depth, latency|
          {t: t, utilisation: utilisation.to_f.round(1), backlog: backlog.to_i,
           queue_depth: depth.to_i, queue_latency: (latency.to_i / 1000.0).round(1)}
        end
    end

    # Deepest depth reported for each queue across `samples`, most backed up
    # first. Every worker reports the same shared queue, so the readings are
    # merged with max, not summed.
    def self.queue_depths(samples)
      depths = samples.each_with_object({}) do |sample, out|
        sample.detail.fetch("queues", {}).each { |queue, depth| out[queue] = [out[queue].to_i, depth.to_i].max }
      end
      depths.sort_by { |_queue, depth| -depth }.map { |queue, depth| {queue: queue, depth: depth} }
    end

    # The recurring task keys Solid Queue is running, from the newest live
    # sample that carries a manifest (the gem sends one on every health
    # sample). nil when no live process has reported one: an older gem, or
    # nothing alive to ask.
    def self.recurring_task_keys(since: LIVE_WINDOW.ago)
      manifest = where(sampled_at: since..).where("json_extract(detail, '$.recurring_tasks') IS NOT NULL")
        .recent.pick(Arel.sql("json_extract(detail, '$.recurring_tasks')"))
      manifest && JSON.parse(manifest).keys
    end

    def self.bucket_expression(bucket)
      seconds = bucket.to_i
      Arel.sql("strftime('%Y-%m-%dT%H:%M:00Z', (strftime('%s', sampled_at) / #{seconds}) * #{seconds}, 'unixepoch')")
    end
    private_class_method :bucket_expression

    def thread_utilisation
      return nil if threads_max.to_i.zero?
      threads_busy.to_f / threads_max
    end
  end
end
