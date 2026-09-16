# frozen_string_literal: true

module Ingest
  # Writes one batch into the environment's telemetry database: rows are
  # grouped by table and bulk-inserted inside a single transaction, then the
  # follow-up work (issue grouping, rollups) is enqueued. Unknown or
  # malformed records are counted as rejected, never raised.
  class Batch
    Result = Struct.new(:accepted, :rejected, :rejections, keyword_init: true) do
      def to_h = { accepted: accepted, rejected: rejected, rejections: rejections.first(10) }
    end

    # embedded: this batch is being written in the monitored application's own
    # process rather than served over HTTP. Quota accounting is a platform
    # concern, and count_events! writes the PRIMARY database on every batch --
    # exactly the customer-database write an embedded install must not make.
    # The live broadcast stays (it is sub-millisecond and throttled to once
    # every 2s) but must not be able to break ingest in an app that has no
    # Action Cable adapter configured.
    def initialize(environment, records, dropped_by_client: 0, backpressure_factor: nil, bytes: 0, gem_version: nil,
                   received_at: nil, embedded: false)
      @embedded = embedded
      @environment = environment
      @records = records
      @dropped_by_client = dropped_by_client
      @backpressure_factor = normalize_backpressure_factor(backpressure_factor)
      @bytes = bytes
      @gem_version = gem_version
      @received_at = received_at || Time.current
      @rejections = []
      @truncations = []
      @counts = Hash.new(0)
      @rows_by_class = Hash.new { |h, k| h[k] = [] }
      @people = []
      @rollup_buckets = Set.new
      @session_buckets = Set.new
      @bucket_cache = {}
      @exception_ids = []
    end

    def write!
      map_all
      log_truncations
      accepted = 0
      Railwatch.span("ingest.write", records: @records.size) do
        @environment.with_telemetry do
          TelemetryRecord.transaction do
            @exception_ids = Ingest::Writer.new(@rows_by_class).write!
            link_profiles!
            accepted += @rows_by_class.values.sum(&:size)
            Telemetry::Person.touch_all(@people.map { |rec| [ rec, Time.at(rec["timestamp"].to_f).utc ] })
            accepted += @people.size
            Telemetry::IngestBatch.create!(received_at: @received_at, accepted: accepted, rejected: @rejections.size,
                                           dropped_by_client: @dropped_by_client, backpressure_factor: @backpressure_factor,
                                           bytes: @bytes, gem_version: @gem_version,
                                           counts_by_type: @counts, rejections: @rejections.first(20))
          end
        end
      end

      if @embedded
        touch_last_seen
      else
        @environment.count_events!(accepted)
      end
      enqueue_followups
      broadcast_live
      Result.new(accepted: accepted, rejected: @rejections.size, rejections: @rejections)
    end

    private

    ROLLED_UP = %w[request job_attempt scheduled_task command channel_action query outgoing_request cache_event mail visit notification span llm_call].freeze
    MAX_PAST_AGE = 30.days
    MAX_FUTURE_AGE = 1.hour

    def normalize_backpressure_factor(value)
      factor = Float(value, exception: false)
      return 1.0 unless factor&.finite?

      [ factor, 1.0 ].max
    end

    # Puma runs one process with a pool of threads in this app (see bin/dev),
    # so a plain Concurrent::Map keyed by environment id is enough to
    # throttle across every thread writing batches -- no need for Rails.cache
    # (which is :null_store in test anyway, so it wouldn't throttle there at
    # all) or a database column. This does not coordinate across separate
    # Puma *worker processes*; under cluster mode a busy environment could
    # broadcast up to once per 2s per worker instead of once globally, which
    # is fine since these broadcasts are only a "data changed, go refetch"
    # ping, not the data itself.
    LAST_BROADCAST_AT = Concurrent::Map.new
    THROTTLE_WINDOW = 2.seconds

    # RollupJob's limits_concurrency only discards an enqueue while a run
    # for that bucket is queued or running; with a batch landing every
    # second, the next enqueue arrives the moment the previous run finishes,
    # and the rollups worker recomputed one busy hour 1,200 times an hour.
    # One enqueue per bucket per window from here; RollupCatchupJob sweeps
    # the current and previous hour every 5 minutes regardless.
    LAST_ROLLUP_ENQUEUE_AT = Concurrent::Map.new
    ROLLUP_ENQUEUE_WINDOW = 60.seconds

    def map_all
      @records.each do |rec|
        Ingest::Mapper.validate_record!(rec)
        type = rec["t"]
        unless timestamp_in_range?(rec["timestamp"])
          reject(rec, "timestamp out of range")
          next
        end
        if type == "user"
          @people << Ingest::Mapper.person_record(rec)
          @counts[type] += 1
          next
        end
        row = Ingest::Mapper.row_for(rec, truncations: @truncations)
        if row.nil?
          reject(rec, "unknown type")
          next
        end
        klass, attrs = row
        @rows_by_class[klass] << attrs
        @counts[type] += 1
        if ROLLED_UP.include?(type)
          @rollup_buckets << bucket_for(rec["timestamp"])
        elsif type == "session"
          # Sessions get their own hourly table rather than the t-digest
          # rollups: what release health needs is each session's worst status,
          # not duration percentiles.
          @session_buckets << bucket_for(rec["timestamp"])
        end
      rescue ArgumentError, TypeError, KeyError, NoMethodError, RangeError, JSON::GeneratorError => e
        reject(rec, "#{e.class}: #{e.message}")
      rescue StandardError => e
        Rails.error.report(e, handled: true, context: { ingest_record_type: record_type(rec) })
        reject(rec, "invalid record")
      end
    end

    def timestamp_in_range?(value)
      raise TypeError, "timestamp must be a number" unless value.is_a?(Numeric)

      timestamp = value.to_f
      raise RangeError, "timestamp is not finite" unless timestamp.finite?

      timestamp.between?((@received_at - MAX_PAST_AGE).to_f, (@received_at + MAX_FUTURE_AGE).to_f)
    end

    def bucket_for(value)
      seconds = (Float(value) * 1_000_000).round / 1_000_000
      hour = seconds - (seconds % 1.hour)
      @bucket_cache[hour] ||= Telemetry::Rollup.bucket_for(Time.zone.at(hour))
    end

    # executions.profile_id is denormalised so a request list or detail page
    # can tell "this one was profiled" without touching the profiles table.
    # The writer does not hand profile ids back, so the freshly inserted
    # rows are matched by execution_id in one correlated UPDATE. The profile
    # and its execution usually arrive in the same batch, but not always --
    # this only links the ones present here; a late profile links on its own
    # batch, a late execution stays unlinked until the page falls back to
    # looking the profile up by execution_id.
    def link_profiles!
      execution_ids = @rows_by_class.fetch(Telemetry::Profile, []).filter_map { |attrs| attrs[:execution_id] }.uniq
      return if execution_ids.empty?
      Telemetry::Execution.where(execution_id: execution_ids)
        .update_all("profile_id = (SELECT MAX(profiles.id) FROM profiles WHERE profiles.execution_id = executions.execution_id)")
    end

    def reject(rec, reason)
      @rejections << { type: record_type(rec), reason: reason.to_s.first(200) }
    end

    def record_type(rec)
      rec.is_a?(Hash) && rec["t"].is_a?(String) ? rec["t"].first(64) : nil
    end

    def log_truncations
      return if @truncations.empty?

      counts = @truncations.tally.sort.to_h
      Rails.logger.info("ingest truncated #{@truncations.size} field(s) for #{@environment.slug}: #{counts.to_json}")
    end

    def enqueue_followups
      GroupExceptionsJob.perform_later(@environment, @exception_ids) if @exception_ids.any?
      @rollup_buckets.each { |bucket| RollupJob.perform_later(@environment, bucket) if rollup_due?(bucket) }
      @session_buckets.each { |bucket| ReleaseHealthRollupJob.perform_later(@environment, bucket) }
    end

    # Embedded installs skip quota accounting, but last_seen_at still drives
    # the "last seen" display and SilentHostCheckJob. One primary-database
    # write per minute, not one per batch.
    LAST_SEEN_TOUCH_AT = Concurrent::Map.new
    LAST_SEEN_TOUCH_WINDOW = 60.seconds

    def touch_last_seen
      now = Time.current
      last = LAST_SEEN_TOUCH_AT[@environment.id]
      return if last && now - last < LAST_SEEN_TOUCH_WINDOW

      LAST_SEEN_TOUCH_AT[@environment.id] = now
      @environment.update_columns(last_seen_at: now)
    end

    def rollup_due?(bucket)
      key = [ @environment.id, bucket.to_i ]
      now = Time.current
      last = LAST_ROLLUP_ENQUEUE_AT[key]
      return false if last && now - last < ROLLUP_ENQUEUE_WINDOW

      LAST_ROLLUP_ENQUEUE_AT[key] = now
      true
    end

    def broadcast_live
      now = Time.current
      last = LAST_BROADCAST_AT[@environment.id]
      return if last && now - last < THROTTLE_WINDOW

      LAST_BROADCAST_AT[@environment.id] = now
      ActionCable.server.broadcast("environment_#{@environment.id}", { event: "ingested", at: now.iso8601, counts: @counts })
    rescue StandardError => e
      # A live refresh ping is not worth failing a written batch over.
      Rails.error.report(e, handled: true, context: { ingest_broadcast: @environment.slug })
    end
  end
end
