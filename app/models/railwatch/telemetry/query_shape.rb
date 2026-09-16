# frozen_string_literal: true

module Railwatch
  module Telemetry
    # One query group's normalized statement, stored once. The group hash is
    # the gem's digest of the connection name and that statement, so a row
    # whose own text digests to its group carries the statement and stores
    # "" instead (Ingest::Writer); any other text stays on the row. See
    # docs/architecture.md.
    class QueryShape < TelemetryRecord
      self.primary_key = :group_hash

      BACKFILL_BATCH = 20_000

      # Backfill for rows written before this table existed. Files a shape
      # for each group whose earliest or newest row normalizes back to the
      # group hash (a tenant's earliest rows may predate the gem sending
      # normalized text; its newest will not), then blanks every row whose
      # text is its group's shape, in id-range batches so no statement holds
      # the tenant's write lock for long. Idempotent, and never blanks a row
      # whose text is not on file. Returns what it did.
      def self.dedupe_rows!(batch: BACKFILL_BATCH)
        before = count
        file_shapes!
        moved = Query.where.not(sql: "")
                     .where("queries.sql = (SELECT s.sql FROM query_shapes s WHERE s.group_hash = queries.group_hash)")
                     .in_batches(of: batch, use_ranges: true).update_all(sql: "")
        { shapes: count - before, rows: moved }
      end

      def self.file_shapes!
        ends = "SELECT MIN(id) AS id FROM queries WHERE group_hash IS NOT NULL GROUP BY group_hash " \
               "UNION SELECT MAX(id) FROM queries WHERE group_hash IS NOT NULL GROUP BY group_hash"
        candidates = Query.joins("JOIN (#{ends}) ends ON ends.id = queries.id").where.not(sql: "")
                          .pluck(:group_hash, :sql, :adapter, :connection)
        shapes = candidates.filter_map do |group_hash, sql, adapter, connection|
          digest, normalized = Railwatch::SqlNormalizer.group_and_normalized(sql, adapter: adapter, connection_name: connection)
          { group_hash: group_hash, sql: normalized } if digest == group_hash
        end
        shapes.uniq { |shape| shape[:group_hash] }.each_slice(500) { |slice| insert_all(slice) }
      end
      private_class_method :file_shapes!
    end
  end
end
