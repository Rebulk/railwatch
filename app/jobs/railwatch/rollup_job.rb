# frozen_string_literal: true

module Railwatch
  # Recomputes the hourly rollups for one bucket from raw rows. Idempotent:
  # runs again whenever new rows land in that hour. Debounced twice: Ingest::
  # Batch enqueues at most one run per bucket per minute, and Solid Queue's
  # concurrency control discards an enqueue while a run for that bucket is
  # already queued or running (the default :block would let a busy hour pile
  # up thousands of identical jobs). RollupCatchupJob sweeps the current and
  # previous hour on its recurring schedule for anything either debounce
  # dropped; an embedded install instead runs this once an hour for the
  # previous hour from Railwatch::Maintenance, since its batches already
  # fold themselves into the current hour as they land.
  class RollupJob < ApplicationJob
    queue_as :rollups
    if respond_to?(:limits_concurrency)
      limits_concurrency to: 1, key: ->(environment, bucket) { "#{environment.id}:#{bucket.to_i}" }, duration: 10.minutes, on_conflict: :discard
    end

    SOURCES = {
      "request" => [ Telemetry::Execution, ->(r) { r.requests }, ->(row) { row.name } ],
      "job_attempt" => [ Telemetry::Execution, ->(r) { r.jobs }, ->(row) { row.name } ],
      "scheduled_task" => [ Telemetry::Execution, ->(r) { r.scheduled }, ->(row) { row.name } ],
      "command" => [ Telemetry::Execution, ->(r) { r.commands }, ->(row) { row.name } ],
      "channel_action" => [ Telemetry::Execution, ->(r) { r.channels }, ->(row) { row.name } ],
      "query" => [ Telemetry::Query, ->(r) { r }, ->(row) { row.sql.first(255) } ],
      "outgoing_request" => [ Telemetry::OutgoingRequest, ->(r) { r }, ->(row) { "#{row.method} #{row.host}" } ],
      "cache_event" => [ Telemetry::CacheEvent, ->(r) { r }, ->(row) { "#{row.store} #{row.key}" } ],
      "mail" => [ Telemetry::Mail, ->(r) { r }, ->(row) { row.mailer } ],
      "visit" => [ Telemetry::Visit, ->(r) { r }, ->(row) { row.component } ],
      "span" => [ Telemetry::Span, ->(r) { r }, ->(row) { row.name } ],
      "notification" => [ Telemetry::Notification, ->(r) { r }, ->(row) { row.notifier || row.delivery_method } ],
      "view_render" => [ Telemetry::ViewRender, ->(r) { r }, ->(row) { row.identifier } ],
      "transaction" => [ Telemetry::Transaction, ->(r) { r }, ->(row) { "#{row.connection} · #{row.outcome}" } ],
      "llm_call" => [ Telemetry::LlmCall, ->(r) { r.models }, ->(row) { "#{row.model} · #{row.operation}" } ],
      "llm_tool" => [ Telemetry::LlmCall, ->(r) { r.tools }, ->(row) { row.tool_name.to_s } ]
    }.freeze

    # SQLite binds at most 32,766 variables per statement; a rollup row is 14.
    INSERT_SLICE = 500

    def perform(environment, bucket)
      bucket = bucket.utc.beginning_of_hour
      range = bucket...(bucket + 1.hour)
      # Recomputing a busy hour is thousands of queries; recording each of
      # them into Railwatch's own telemetry was 70% of everything this platform
      # ingested about itself. The job record still ships with its duration.
      environment.with_telemetry do
        Railwatch.ignore { recompute(environment, bucket, range) }
      end
    end

    private

    # Every group of one type is written in one transaction: the hour's
    # rollups for that type replace each other atomically, and the write lock
    # is held only for the writes. Rails opens each SQLite transaction
    # IMMEDIATE, so reading the hour inside it would hold every other writer
    # off the tenant file for the whole read -- a busy hour is tens of
    # seconds, and ingest gets five before it gives up. On 2026-09-05 one
    # 37-second recompute failed every batch that arrived while it ran.
    def recompute(environment, bucket, range)
      SOURCES.each do |type, (klass, scope, namer)|
        Railwatch.span("rollup.#{type}", bucket: bucket.iso8601) do
          rows = scope.call(klass).where(occurred_at: range).select(:id, :group_hash, :duration, *(klass == Telemetry::Execution ? %i[name status outcome kind] : %i[]), *(klass == Telemetry::Query ? [ Telemetry::Query::SQL ] : []), *(klass == Telemetry::OutgoingRequest ? %i[method host status_code] : []), *(klass == Telemetry::CacheEvent ? %i[store key type] : []), *(klass == Telemetry::Mail ? %i[mailer failed] : []), *(klass == Telemetry::Visit ? %i[component status] : []), *(klass == Telemetry::Notification ? %i[notifier delivery_method failed] : []), *(klass == Telemetry::ViewRender ? %i[identifier kind] : []), *(klass == Telemetry::Transaction ? %i[outcome connection] : []), *(klass == Telemetry::Span ? %i[name status] : []), *(klass == Telemetry::LlmCall ? %i[operation model tool_name status input_tokens output_tokens cache_read_tokens cache_write_tokens cost_nanos finish_reason attachments] : []))
          groups = rows.group_by(&:group_hash).except(nil)
          next if groups.empty?
          rows = groups.map do |group_hash, group|
            Telemetry::Rollup.fresh_attributes(
              record_type: type, group_hash: group_hash, name: namer.call(group.first).to_s, bucket: bucket,
              durations: group.map(&:duration),
              errors: group.count { |r| error?(type, r) },
              client_errors: group.count { |r| type == "request" && r.status.to_i.between?(400, 499) },
              extra: extra_for(type, group))
          end
          # One DELETE and a few INSERTs per type instead of a SELECT, a DELETE
          # and an INSERT per group: a busy hour of queries is 2,000 groups,
          # and this job was 20,000 of the platform's own N+1 records a week.
          Telemetry::Rollup.transaction do
            # The hour was read outside this transaction (above), so a batch
            # that landed in between has already been folded into the row
            # about to be replaced (Ingest::RollupAbsorber). A stored count
            # higher than the recomputed one means exactly that: keep the
            # stored row rather than overwrite it with a snapshot that
            # predates the batch. The next run picks the group up.
            stored = Telemetry::Rollup.where(record_type: type, group_hash: groups.keys, bucket: bucket).pluck(:group_hash, :count).to_h
            rows = rows.reject { |row| stored[row[:group_hash]].to_i > row[:count] }
            next if rows.empty?

            Telemetry::Rollup.where(record_type: type, group_hash: rows.map { |row| row[:group_hash] }, bucket: bucket).delete_all
            rows.each_slice(INSERT_SLICE) { |slice| Telemetry::Rollup.insert_all(slice) }
          end
        end
      end
    end

    def error?(type, row)
      case type
      when "request" then row.status.to_i >= 500
      when "job_attempt", "scheduled_task", "channel_action" then row.outcome == "failed"
      when "command" then row.status.to_i != 0
      when "outgoing_request" then row.status_code.to_i >= 500 || row.status_code.to_i.zero?
      when "mail" then row.failed
      when "visit" then row.status == "error"
      when "notification" then row.failed
      when "transaction" then row.outcome == "rollback"
      when "span", "llm_call", "llm_tool" then row.status == "failed"
      else false
      end
    end

    def extra_for(type, group)
      case type
      when "cache_event"
        { hits: group.count { |r| r.type == "hit" }, misses: group.count { |r| r.type == "miss" || r.type == "generate" } }
      when "view_render"
        { kind: group.group_by(&:kind).max_by { |_kind, rows| rows.size }&.first }
      when "llm_call"
        { input_tokens: group.sum { |r| r.input_tokens.to_i }, output_tokens: group.sum { |r| r.output_tokens.to_i },
         cache_read_tokens: group.sum { |r| r.cache_read_tokens.to_i }, cache_write_tokens: group.sum { |r| r.cache_write_tokens.to_i },
         cost_nanos: group.sum { |r| r.cost_nanos.to_i },
         priced: group.count { |r| r.cost_nanos },
         unpriced: group.count { |r| r.cost_nanos.nil? },
         # A cut-off answer is not an error and will never show in the error
         # rate, so it needs counting on its own or it stays invisible.
         truncated: group.count { |r| r.finish_reason == "max_tokens" },
         with_attachments: group.count { |r| r.attachments.to_i.positive? } }
      else {}
      end
    end
  end
end
