# frozen_string_literal: true

module Railwatch
  module Ingest
    # Folds one batch's rows into the hourly rollups as they land, so a count
    # or a percentile on the dashboard moves with every batch instead of
    # waiting for RollupJob to recompute the hour from raw rows. Same
    # classification as RollupJob (which stays as the reconciler for anything
    # this missed), applied to the mapped row hashes before they are inserted
    # rather than to Active Record rows read back afterwards.
    #
    # One SELECT for the groups this batch touches, the merge in Ruby, one
    # upsert: the read and the write both stay small whatever the hour holds,
    # so this never grows into the 100 ms recompute that RollupJob is on a
    # busy hour. It runs inside the batch's transaction.
    class RollupAbsorber
      # record_type => [table class, row filter, group name]. Executions carry
      # their kind on the row; LLM calls split into models and tools.
      SOURCES = {
        "request" => [ Telemetry::Execution, ->(r) { r[:kind] == "request" }, ->(r) { r[:name] } ],
        "job_attempt" => [ Telemetry::Execution, ->(r) { r[:kind] == "job_attempt" }, ->(r) { r[:name] } ],
        "scheduled_task" => [ Telemetry::Execution, ->(r) { r[:kind] == "scheduled_task" }, ->(r) { r[:name] } ],
        "command" => [ Telemetry::Execution, ->(r) { r[:kind] == "command" }, ->(r) { r[:name] } ],
        "channel_action" => [ Telemetry::Execution, ->(r) { r[:kind] == "channel_action" }, ->(r) { r[:name] } ],
        "query" => [ Telemetry::Query, ->(_r) { true }, ->(r) { r[:sql].to_s } ],
        "outgoing_request" => [ Telemetry::OutgoingRequest, ->(_r) { true }, ->(r) { "#{r[:method]} #{r[:host]}" } ],
        "cache_event" => [ Telemetry::CacheEvent, ->(_r) { true }, ->(r) { "#{r[:store]} #{r[:key]}" } ],
        "mail" => [ Telemetry::Mail, ->(_r) { true }, ->(r) { r[:mailer] } ],
        "visit" => [ Telemetry::Visit, ->(_r) { true }, ->(r) { r[:component] } ],
        "span" => [ Telemetry::Span, ->(_r) { true }, ->(r) { r[:name] } ],
        "notification" => [ Telemetry::Notification, ->(_r) { true }, ->(r) { r[:notifier] || r[:delivery_method] } ],
        "view_render" => [ Telemetry::ViewRender, ->(_r) { true }, ->(r) { r[:identifier] } ],
        "transaction" => [ Telemetry::Transaction, ->(_r) { true }, ->(r) { "#{r[:connection]} · #{r[:outcome]}" } ],
        "llm_call" => [ Telemetry::LlmCall, ->(r) { r[:operation] != Telemetry::LlmCall::TOOL }, ->(r) { "#{r[:model]} · #{r[:operation]}" } ],
        "llm_tool" => [ Telemetry::LlmCall, ->(r) { r[:operation] == Telemetry::LlmCall::TOOL }, ->(r) { r[:tool_name].to_s } ]
      }.freeze

      # SQLite binds at most 32,766 variables per statement; a rollup row is 14.
      UPSERT_SLICE = 500

      def initialize(rows_by_class, query_shapes: {})
        @rows_by_class = rows_by_class
        # Writer files a query's text on its shape and blanks the row, so the
        # group's name has to come from the shape when the row is empty.
        @query_shapes = query_shapes
      end

      # Groups every rolled-up row by (type, group, hour), merges each group
      # into its existing rollup row if there is one, and writes them back.
      def absorb!
        pending = collect
        return 0 if pending.empty?

        existing = load_existing(pending.keys)
        rows = pending.map { |key, group| merged_row(key, group, existing[key]) }
        rows.each_slice(UPSERT_SLICE) do |slice|
          Telemetry::Rollup.upsert_all(slice, unique_by: %i[record_type group_hash bucket], record_timestamps: false)
        end
        rows.size
      end

      private

      # { [type, group_hash, bucket] => { name:, durations:, errors:, client_errors:, extra: } }
      def collect
        pending = {}
        SOURCES.each do |type, (klass, filter, namer)|
          @rows_by_class.fetch(klass, []).each do |row|
            next unless filter.call(row)
            group_hash = row[:group_hash]
            duration = row[:duration]
            next if group_hash.nil? || duration.nil?

            bucket = bucket_for(row[:occurred_at])
            next unless bucket

            entry = pending[[ type, group_hash, bucket ]] ||= { name: nil, durations: [], errors: 0, client_errors: 0, extra: Hash.new(0) }
            entry[:name] ||= name_for(type, row, namer)
            entry[:durations] << duration.to_i
            entry[:errors] += 1 if error?(type, row)
            entry[:client_errors] += 1 if type == "request" && row[:status].to_i.between?(400, 499)
            add_extra(type, row, entry[:extra])
          end
        end
        pending
      end

      def load_existing(keys)
        found = {}
        keys.group_by { |type, _group, bucket| [ type, bucket ] }.each do |(type, bucket), group_keys|
          Telemetry::Rollup.where(record_type: type, bucket: bucket, group_hash: group_keys.map { |k| k[1] })
                           .each { |row| found[[ type, row.group_hash, bucket ]] = row }
        end
        found
      end

      def merged_row((type, group_hash, bucket), group, existing)
        digest = existing&.digest ? TDigest::TDigest.from_bytes(existing.digest) : TDigest::TDigest.new(0.01)
        group[:durations].each { |d| digest.push(d) }
        digest.compress!
        extra = existing ? existing.extra.merge(group[:extra]) { |_k, a, b| a.is_a?(Numeric) && b.is_a?(Numeric) ? a + b : b } : group[:extra].to_h
        {
          record_type: type, group_hash: group_hash, bucket: bucket,
          name: (group[:name].presence || existing&.name || "").to_s.first(255),
          count: existing&.count.to_i + group[:durations].size,
          error_count: existing&.error_count.to_i + group[:errors],
          client_error_count: existing&.client_error_count.to_i + group[:client_errors],
          duration_sum: existing&.duration_sum.to_i + group[:durations].sum,
          duration_max: [ existing&.duration_max.to_i, group[:durations].max ].max,
          p50: digest.percentile(0.5).to_i, p95: digest.percentile(0.95).to_i, p99: digest.percentile(0.99).to_i,
          digest: digest.as_small_bytes, extra: extra
        }
      end

      # Mapper writes occurred_at as a UTC string; the hour is its prefix.
      def bucket_for(occurred_at)
        return nil if occurred_at.nil?

        @buckets ||= {}
        @buckets[occurred_at.to_s[0, 13]] ||= Time.zone.parse(occurred_at.to_s)&.utc&.beginning_of_hour
      end

      def name_for(type, row, namer)
        if type == "query"
          text = row[:sql].to_s
          text = @query_shapes[row[:group_hash]].to_s if text.empty?
          text.first(255)
        else
          namer.call(row).to_s
        end
      end

      def error?(type, row)
        case type
        when "request" then row[:status].to_i >= 500
        when "job_attempt", "scheduled_task", "channel_action" then row[:outcome] == "failed"
        when "command" then row[:status].to_i != 0
        when "outgoing_request" then row[:status_code].to_i >= 500 || row[:status_code].to_i.zero?
        when "mail", "notification" then row[:failed] ? true : false
        when "visit" then row[:status] == "error"
        when "transaction" then row[:outcome] == "rollback"
        when "span", "llm_call", "llm_tool" then row[:status] == "failed"
        else false
        end
      end

      def add_extra(type, row, extra)
        case type
        when "cache_event"
          extra["hits"] += 1 if row[:type] == "hit"
          extra["misses"] += 1 if row[:type] == "miss" || row[:type] == "generate"
        when "view_render"
          # RollupJob stores the hour's commonest kind; a batch cannot know
          # that, so the latest seen wins. Same shape, close enough.
          extra["kind"] = row[:kind] if row[:kind]
        when "llm_call"
          extra["input_tokens"] += row[:input_tokens].to_i
          extra["output_tokens"] += row[:output_tokens].to_i
          extra["cache_read_tokens"] += row[:cache_read_tokens].to_i
          extra["cache_write_tokens"] += row[:cache_write_tokens].to_i
          extra["cost_nanos"] += row[:cost_nanos].to_i
          extra["priced"] += 1 if row[:cost_nanos]
          extra["unpriced"] += 1 if row[:cost_nanos].nil? && row[:status] != "failed"
          extra["truncated"] += 1 if row[:finish_reason] == "max_tokens"
          extra["with_attachments"] += 1 if row[:attachments].to_i.positive?
        end
      end
    end
  end
end
