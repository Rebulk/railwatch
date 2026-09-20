# frozen_string_literal: true

module Railwatch
  # Deletes raw rows past the account's retention window. Rollups are kept
  # for 13 months so long-range charts keep working after raw rows are gone.
  # Telemetry::Session is monitored-application telemetry; dashboard login
  # sessions live in the primary database and are deliberately not touched.
  class PruneTelemetryJob < ApplicationJob
    queue_as :maintenance

    AGGREGATE_RETENTION = 13.months
    # Sessions have never been pruned, so the first run of this job would walk
    # every hour an environment has ever recorded. Delete a bounded number of
    # hourly buckets per run and let the nightly schedule drain the backlog.
    SESSION_HOURS_PER_RUN = 48
    BATCH = 5_000
    # Per raw table per run. A backlog past this (a retention change, a
    # restore of an old file) drains over successive runs rather than in one
    # that holds SQLite's write lock for as long as it takes. In the embedded
    # writer that long hold would look like a wedge and end the process.
    MAX_BATCHES_PER_TABLE = 40

    # Reclaim, bounded the same way the deletes are. Deleting rows only moves
    # their pages to the freelist; PRAGMA incremental_vacuum is what hands
    # them back to the filesystem, and it is only possible at all on a
    # database in auto_vacuum=incremental (EnableIncrementalVacuum, or
    # `bin/rails railwatch:vacuum` for a database that predates it).
    # Measured at 80k-190k pages/s warm, so a full run is well under a second
    # there; the slicing is for the cold, large file, where each slice takes
    # and releases the write lock instead of holding it throughout.
    VACUUM_PAGES_PER_SLICE = 2_000
    # 50k pages, ~200MB at SQLite's 4KB default. A few thousand pages a night
    # would never keep up with a night's deletes on a busy app, and the file
    # would go on growing with the freelist; a backlog past this one still
    # drains over successive nightly runs.
    VACUUM_SLICES = 25

    RAW = [ Telemetry::Execution, Telemetry::Query, Telemetry::Exception, Telemetry::CacheEvent, Telemetry::Mail,
            Telemetry::Broadcast, Telemetry::Notification, Telemetry::OutgoingRequest, Telemetry::StorageOp,
            Telemetry::ViewRender, Telemetry::Log, Telemetry::EnqueuedJob, Telemetry::Transaction,
            Telemetry::NPlusOne, Telemetry::Deprecation, Telemetry::Visit, Telemetry::Span,
            Telemetry::LlmCall,
            Telemetry::Profile, Telemetry::Attachment ].freeze

    # checkpoint: the WAL checkpoint mode run at the end. TRUNCATE (the
    # default, for a dedicated worker) hands the space back to the filesystem
    # but blocks every reader and writer while it does; PASSIVE checkpoints
    # what it can without waiting on anyone, which is what a prune running
    # inside a Puma worker (Railwatch::Maintenance) must use.
    def perform(environment = nil, checkpoint: "TRUNCATE")
      return [ Environment.current ].each { |env| self.class.perform_later(env) } if environment.nil?

      cutoff = environment.retention_days.days.ago
      aggregate_cutoff = AGGREGATE_RETENTION.ago
      environment.with_telemetry do
        unindex_logs(cutoff) if Telemetry::Log.fts_available?
        RAW.each { |klass| prune(klass, cutoff) }
        # NOT EXISTS rather than NOT IN: queries.group_hash is nullable, and one
        # NULL in a NOT IN subquery makes it match nothing. A few hundred shapes.
        Telemetry::QueryShape.where("NOT EXISTS (SELECT 1 FROM queries WHERE queries.group_hash = query_shapes.group_hash)").delete_all
        prune_sessions(cutoff)
        Telemetry::Rollup.where(bucket: ...aggregate_cutoff).delete_all
        Telemetry::ReleaseHealth.where(bucket: ...aggregate_cutoff).in_batches(of: 5_000).delete_all
        Telemetry::Person.where(last_seen_at: ...cutoff).in_batches(of: 5_000).delete_all
        Telemetry::IngestBatch.where(received_at: ...cutoff).delete_all
        Telemetry::Process.where(booted_at: ...cutoff).delete_all
        Telemetry::HealthSample.where(sampled_at: ...cutoff).delete_all
        # Before the checkpoint, not after: incremental_vacuum truncates the
        # database file, and in WAL mode that truncation only reaches the file
        # on disk once it is checkpointed.
        TelemetryRecord.reclaim_freelist!(slice: VACUUM_PAGES_PER_SLICE, slices: VACUUM_SLICES)
        TelemetryRecord.connection.execute("PRAGMA wal_checkpoint(#{checkpoint})") if TelemetryRecord.sqlite?
      end
    end

    private

    # in_batches walks a table by primary key: its probe is "WHERE occurred_at
    # < ? ORDER BY id LIMIT n", which no index serves, so SQLite scanned the
    # whole table by rowid to find nothing to delete -- 42 seconds on the
    # platform's own 12M-row queries table, every night, for an empty result.
    # Ordered by occurred_at the same probe is one seek on any index led by
    # that column, and the first page of expired rows is exactly the oldest
    # ones. Tables without such an index still scan, but they are the small
    # ones.
    def prune(klass, cutoff)
      MAX_BATCHES_PER_TABLE.times do
        # Ordered by (occurred_at, id), not occurred_at alone: rows that tie
        # on the timestamp at the limit boundary would otherwise be a
        # different set here than in unindex_logs above, which leaves stale
        # FTS postings behind and withdraws postings for logs that are staying.
        ids = klass.where(occurred_at: ...cutoff).order(:occurred_at, :id).limit(BATCH).pluck(:id)
        break if ids.empty?
        klass.where(id: ids).delete_all
        break if ids.size < BATCH
      end
    end

    # Sessions are the raw input to the hourly release_health aggregate, so they
    # are deleted a whole hour at a time. Flooring the cutoff to the start of its
    # hour leaves the partial hour straddling the boundary in place: deleting
    # only its expired prefix would let the next rollup rebuild that hour from
    # the surviving tail and silently shrink an already correct aggregate.
    def prune_sessions(cutoff)
      expired = Telemetry::Session.where(occurred_at: ...cutoff.utc.beginning_of_hour)
      SESSION_HOURS_PER_RUN.times do
        oldest = expired.minimum(:occurred_at)
        break if oldest.nil?

        hour = oldest.utc.beginning_of_hour
        expired.where(occurred_at: hour...(hour + 1.hour)).in_batches(of: 5_000).delete_all
      end
    end

    # logs_fts is an external-content index with no triggers, so the postings
    # for a log line have to be withdrawn while its row (and message) is still
    # there. Deleting the rows first would leave the index permanently out of
    # sync -- searches would keep returning rowids that no longer exist.
    # Bounded the same way as the rows it precedes: the postings for at most
    # MAX_BATCHES_PER_TABLE * BATCH expired lines are withdrawn per run, which
    # is exactly the set prune(Telemetry::Log) will delete this run.
    def unindex_logs(cutoff)
      Telemetry::Log.connection.execute(Telemetry::Log.sanitize_sql_array([
        "INSERT INTO logs_fts(logs_fts, rowid, message) SELECT 'delete', id, message FROM logs " \
        "WHERE occurred_at < ? ORDER BY occurred_at, id LIMIT ?", cutoff, MAX_BATCHES_PER_TABLE * BATCH
      ]))
    end
  end
end
