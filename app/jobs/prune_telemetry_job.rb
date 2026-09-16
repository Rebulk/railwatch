# frozen_string_literal: true

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

  RAW = [ Telemetry::Execution, Telemetry::Query, Telemetry::Exception, Telemetry::CacheEvent, Telemetry::Mail,
          Telemetry::Broadcast, Telemetry::Notification, Telemetry::OutgoingRequest, Telemetry::StorageOp,
          Telemetry::ViewRender, Telemetry::Log, Telemetry::EnqueuedJob, Telemetry::Transaction,
          Telemetry::NPlusOne, Telemetry::Deprecation, Telemetry::Visit, Telemetry::Span,
          Telemetry::LlmCall,
          Telemetry::Profile, Telemetry::Attachment ].freeze

  def perform(environment = nil)
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
      TelemetryRecord.connection.execute("PRAGMA wal_checkpoint(TRUNCATE)") if TelemetryRecord.connection.adapter_name =~ /sqlite/i
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
    loop do
      ids = klass.where(occurred_at: ...cutoff).order(:occurred_at).limit(BATCH).pluck(:id)
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
  def unindex_logs(cutoff)
    Telemetry::Log.connection.execute(Telemetry::Log.sanitize_sql_array([
      "INSERT INTO logs_fts(logs_fts, rowid, message) SELECT 'delete', id, message FROM logs WHERE occurred_at < ?", cutoff
    ]))
  end
end
