# frozen_string_literal: true

module Telemetry
  # A request, job attempt, scheduled task, command, or channel action. The parent of
  # every other telemetry row via execution_id.
  class Execution < TelemetryRecord
    KINDS = %w[request job_attempt scheduled_task command channel_action].freeze

    scope :of_kind, ->(kind) { where(kind: kind) }
    scope :requests, -> { where(kind: "request") }
    scope :jobs, -> { where(kind: "job_attempt") }
    scope :scheduled, -> { where(kind: "scheduled_task") }
    scope :commands, -> { where(kind: "command") }
    scope :channels, -> { where(kind: "channel_action") }
    scope :recent, -> { order(occurred_at: :desc) }
    scope :between, ->(from, to) { where(occurred_at: from..to) }
    scope :failed, -> { where("status >= 500 OR outcome = 'failed'") }

    # Servers that reported an execution since `time`. Asked once per kind:
    # there is no index led by occurred_at alone, so the obvious
    # `where(occurred_at: time..).distinct.pluck(:server)` scans the whole
    # table -- 15 to 26 seconds every five minutes on the platform's own
    # 500k-row tenant, from SilentHostCheckJob -- while (kind, occurred_at)
    # seeks straight to the window for each of the five kinds.
    def self.servers_since(time)
      KINDS.flat_map { |kind| where(kind: kind, occurred_at: time..).distinct.pluck(:server) }.uniq
    end

    # The schedule string each task key last ran with, in one query: the
    # newest scheduled_task row per key carries it in detail. The scheduled
    # tasks page and CheckScheduledTasksJob both used to look it up per key.
    def self.latest_schedules(keys)
      return {} if keys.empty?
      latest = scheduled.where(task_key: keys).group(:task_key).select(:task_key, Arel.sql("MAX(id) AS id"))
      scheduled.where(id: latest.map(&:id))
        .pluck(:task_key, Arel.sql("json_extract(detail, '$.schedule')")).to_h
    end

    CHILDREN = {
      queries: Query, exceptions: Exception, cache_events: CacheEvent, mails: Mail,
      broadcasts: Broadcast, outgoing_requests: OutgoingRequest, storage_ops: StorageOp,
      view_renders: ViewRender, logs: Log, enqueued_jobs: EnqueuedJob, transactions: Transaction,
      notifications: Notification, spans: Span, profiles: Profile, attachments: Attachment,
      llm_calls: LlmCall
    }.freeze

    CHILDREN.each do |name, klass|
      define_method(name) { klass.where(execution_id: execution_id) }
    end

    # All children merged and ordered for the waterfall timeline.
    def timeline
      CHILDREN.flat_map { |name, klass| klass.timeline_scope(execution_id).map { |r| r.timeline_entry(name) } }
              .sort_by { |e| e[:offset] }
    end

    def failed?
      (status && status >= 500) || outcome == "failed"
    end

    def duration_ms
      duration / 1000.0
    end

    def children_count
      counters.values.sum
    end
  end
end
