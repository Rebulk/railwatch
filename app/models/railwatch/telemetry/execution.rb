# frozen_string_literal: true

module Railwatch
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

      # Executions of `kind` in [from, to] whose name contains `text`, or
      # (with previews: true) whose exception preview does. A LIKE on the rows
      # themselves reads every execution in the window until it has a page:
      # 32 s for a week of the platform's own requests when the text is rare.
      # Names come from a few hundred groups, so the text is matched against
      # the window's rollups and the rows are fetched by group_hash. Rollups
      # trail ingest by up to a minute, so the last FRESH_NAMES are matched on
      # the rows themselves. Only failures carry a preview, and a partial
      # index holds just those rows.
      #
      # Each branch names its index and the outer lookup is by rowid, so the
      # plan does not depend on planner statistics (an embedded install's are
      # sampled, and sampled statistics make kind look selective). When the
      # text is common the old walk is the fast one -- a page of matches
      # turns up in the first few thousand rows -- so a text the rollups say
      # matches DENSE_MATCHES rows or more keeps it. On a copy of the
      # platform's own tenant, a week of job attempts: a text matching
      # nothing took 657 ms walking and 27 ms here; one matching 32,766 took
      # 11 ms walking and 215 ms here.
      FRESH_NAMES = 5.minutes
      DENSE_MATCHES = 1_000

      # `range` is used as given, so an exclusive or empty one (FilterQuery's
      # after:/before: can narrow a window to nothing) stays that way.
      def self.named_like(kind, text, range, previews: false)
        from, to = range.begin, range.end
        pattern = "%#{sanitize_sql_like(text)}%"
        window = where(kind: kind, occurred_at: range)
        groups = Rollup.for_type(kind).between(from, to).where("name LIKE ? ESCAPE '\\'", pattern)
        if !TelemetryRecord.sqlite? || groups.sum(:count) >= DENSE_MATCHES
          like = previews ? "name LIKE :pattern ESCAPE '\\' OR exception_preview LIKE :pattern ESCAPE '\\'" : "name LIKE :pattern ESCAPE '\\'"
          return window.where(like, pattern: pattern)
        end

        by_group = indexed_by("index_executions_on_group_hash_and_occurred_at")
          .where(group_hash: groups.distinct.select(:group_hash), occurred_at: range, kind: kind)
        fresh = where(kind: kind, occurred_at: [ from, to - FRESH_NAMES ].max..to).where("name LIKE ? ESCAPE '\\'", pattern)
        ids = [ by_group, fresh ]
        ids << indexed_by("idx_executions_with_preview").where(kind: kind, occurred_at: range)
          .where.not(exception_preview: nil).where("exception_preview LIKE ? ESCAPE '\\'", pattern) if previews
        from("#{quoted_table_name} NOT INDEXED").where(kind: kind, occurred_at: range)
          .where(ids.map { |branch| "#{quoted_table_name}.id IN (#{branch.select(:id).to_sql})" }.join(" OR "))
      end

      def self.indexed_by(index) = unscoped.from("#{quoted_table_name} INDEXED BY #{index}")
      private_class_method :indexed_by

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
        CHILDREN.flat_map { |name, klass| klass.timeline_scope(execution_id).map { |r| r.timeline_entry(name, occurred_at) } }
                .sort_by { |e| e[:offset] }
      end

      def failed?
        (status && status >= 500) || outcome == "failed"
      end

      def duration_ms
        duration / 1000.0
      end

      def queue_latency_ms
        queue_latency && (queue_latency / 1000.0).round(1)
      end

      # The row every list surface shows for an execution: what the kind has
      # in common, then what it adds.
      def as_row
        row = { execution_id: execution_id, kind: kind, name: name, status: status, outcome: outcome, duration: duration_ms.round(2),
                occurred_at: occurred_at, deploy: deploy, server: server, user_ref: user_ref, tenant: app_tenant,
                exception_preview: exception_preview }
        case kind
        when "request" then row.merge(method: self[:method], inertia_component: inertia_component, queries: counters["queries"])
        when "job_attempt" then row.merge(queue: queue, attempt: attempt, job_id: job_id, queue_latency: queue_latency_ms)
        when "scheduled_task" then row.merge(task_key: task_key)
        else row
        end
      end

      def children_count
        counters.values.sum
      end
    end
  end
end
