# frozen_string_literal: true

module Railwatch
  module Ingest
    # Inserts mapped rows (klass => [row_hash, ...], from Ingest::Mapper.row_for)
    # into the current tenant's telemetry database inside one transaction.
    #
    # On SQLite, binds straight into a prepared statement per (table, column
    # set) instead of going through Active Record's insert machinery — this is
    # the fast path Railwatch is tuned for. The generic insert_all path alone
    # does not make other adapters supported local storage: migrations,
    # search, aggregation and retention must support them as well.
    class Writer
      # Classes whose new rowids we need after the insert: exception ids go
      # back to the caller for grouping, log ids into the full-text index.
      ID_CLASSES = [ Telemetry::Exception, Telemetry::Log ].freeze

      def initialize(rows_by_class)
        @rows_by_class = rows_by_class
      end

      # group_hash => statement, for the queries this batch filed on their
      # shape; RollupAbsorber names a query group from it.
      attr_reader :query_shapes

      def write!
        exception_ids = []
        TelemetryRecord.transaction do
          tables = with_query_shapes(@rows_by_class)
          connection = TelemetryRecord.connection
          exception_ids = connection.adapter_name == "SQLite" ? write_sqlite(connection, tables) : write_generic(tables)
        end
        exception_ids
      end

      private

      # A query's group is the gem's digest of its connection name and its
      # normalized statement, which is the text the gem sends unless it is
      # configured to capture values. A row whose text digests to its group
      # therefore carries the group's statement: it is filed once in
      # query_shapes and the row stores "". Any other text (captured values,
      # a statement the gem truncated, an older gem's raw text) stays on the
      # row. One MD5 per row; the shapes ride the same INSERT OR IGNORE as
      # every table, so a group already on file costs nothing.
      def with_query_shapes(rows_by_class)
        shapes = {}
        rows_by_class.fetch(Telemetry::Query, []).each do |row|
          group_hash = row[:group_hash]
          next unless group_hash && row[:sql].present? && Railwatch::Record.group_hash(row[:connection], row[:sql]) == group_hash

          shapes[group_hash] ||= { group_hash: group_hash, sql: row[:sql] }
          row[:sql] = ""
        end
        @query_shapes = shapes.transform_values { |shape| shape[:sql] }
        shapes.empty? ? rows_by_class : rows_by_class.merge(Telemetry::QueryShape => shapes.values)
      end

      def write_sqlite(connection, tables)
        raw = connection.raw_connection
        ids = Hash.new { |h, k| h[k] = [] }
        tables.each do |klass, rows|
          next if rows.empty?
          table = connection.quote_table_name(klass.table_name)
          rows.group_by(&:keys).each do |columns, group_rows|
            ids[klass].concat(insert_group(raw, connection, table, columns, group_rows, klass))
          end
        end
        index_logs(raw, ids[Telemetry::Log])
        ids[Telemetry::Exception]
      end

      def insert_group(raw, connection, table, columns, rows, klass)
        column_sql = columns.map { |c| connection.quote_column_name(c.to_s) }.join(",")
        placeholders = ([ "?" ] * columns.size).join(",")
        # The gem re-sends a batch after a transport timeout, so the same
        # execution can arrive twice; the unique index on execution_id turns
        # the duplicate into a no-op instead of aborting the whole batch.
        stmt = raw.prepare("INSERT OR IGNORE INTO #{table} (#{column_sql}) VALUES (#{placeholders})")
        ids = []
        begin
          rows.each do |row|
            stmt.bind_params(*columns.map { |c| row[c] })
            stmt.step
            ids << raw.last_insert_row_id if ID_CLASSES.include?(klass) && raw.changes.positive?
            stmt.reset!
          end
        ensure
          stmt.close
        end
        ids
      end

      # logs_fts is an external-content FTS5 table declared without triggers
      # (the schema dumper cannot carry them), so every inserted message has to
      # be copied into the index by hand, inside the same transaction as the
      # rows themselves. Only SQLite has the index; write_generic does nothing.
      def index_logs(raw, ids)
        # A tenant database migrated before the index existed, or one restored
        # from a backup that predates it, must not fail every batch that carries
        # a log line; telemetry:fts:rebuild creates the index later.
        return if ids.empty? || !Telemetry::Log.fts_available?

        ids.each_slice(500) do |slice|
          placeholders = ([ "?" ] * slice.size).join(",")
          raw.execute("INSERT INTO logs_fts(rowid, message) SELECT id, message FROM logs WHERE id IN (#{placeholders})", slice)
        end
      end

      def write_generic(tables)
        exception_ids = []
        tables.each do |klass, rows|
          next if rows.empty?
          result = klass.insert_all(restore_json(klass, rows), record_timestamps: false,
                                    unique_by: (:execution_id if klass == Telemetry::Execution),
                                    returning: klass == Telemetry::Exception ? [ :id ] : false)
          exception_ids.concat(result.rows.flatten) if klass == Telemetry::Exception
        end
        exception_ids
      end

      # insert_all round-trips every value through its column's type (cast
      # then serialize) before quoting it, which is correct for booleans
      # (0/1 casts back to false/true) and timestamps (the formatted string
      # parses back to a Time) but not for a JSON column: its mutable type
      # re-encodes a String as-is instead of parsing it, which would double-
      # encode our pre-serialized JSON. Only this fallback needs the fix —
      # the SQLite fast path writes the encoded string straight through.
      def restore_json(klass, rows)
        json_columns = Ingest::Mapper.columns_for(klass).select { |_, (type, _)| type == :json }.keys.map(&:to_sym)
        return rows if json_columns.empty?
        rows.map do |row|
          row.dup.tap { |r| json_columns.each { |c| r[c] = JSON.parse(r[c]) if r[c].is_a?(String) } }
        end
      end
    end
  end
end
