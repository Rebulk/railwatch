# frozen_string_literal: true

module Railwatch
  module Telemetry
    class Query < TelemetryRecord
      include Child

      # Raised when a row's SQL is read on a relation that did not resolve it.
      class SqlNotResolved < StandardError; end

      # The statement, from the row or from its group's shape (QueryShape).
      # A correlated lookup rather than a join: the queries page sorts a
      # window of millions of rows before taking 50, and a LEFT JOIN there
      # was paid per candidate row (47 s against 0.8 s on the 5M-row window).
      SQL = Arel.sql("COALESCE(NULLIF(queries.sql, ''), " \
                     "(SELECT query_shapes.sql FROM query_shapes WHERE query_shapes.group_hash = queries.group_hash), '') AS resolved_sql").freeze

      # Rows with their SQL resolved in the same statement, so a page loaded
      # inside Environment#with_telemetry can be rendered after the block.
      # Replaces the select list: count with count(:all), and pluck
      # resolved_sql, not sql.
      scope :with_sql, -> { select("queries.*", SQL) }

      # Free-text search over the statement, wherever it is stored.
      scope :matching, ->(text) {
        pattern = "%#{sanitize_sql_like(text)}%"
        where("queries.sql LIKE :pattern ESCAPE '\\' OR queries.name LIKE :pattern ESCAPE '\\' " \
              "OR queries.group_hash IN (SELECT group_hash FROM query_shapes WHERE sql LIKE :pattern ESCAPE '\\')", pattern: pattern)
      }

      def self.timeline_scope(execution_id)
        in_execution(execution_id).with_sql
      end

      # Always a String. A row whose text lives on its shape can only answer
      # through with_sql; asking without it is a bug, not an empty statement.
      def sql
        return self[:resolved_sql].to_s if has_attribute?(:resolved_sql)

        text = self[:sql].to_s
        raise SqlNotResolved, "Telemetry::Query##{id} stores its SQL on its shape; load it through Query.with_sql" if text.empty? && group_hash
        text
      end

      def as_row
        { id: id, group_hash: group_hash, sql: sql.first(2_000), name: name, duration: duration_ms.round(3), occurred_at: occurred_at,
          deploy: deploy, execution_id: execution_id, execution_preview: execution_preview, source: source,
          connection: connection, role: role, adapter: adapter, row_count: row_count, tenant: app_tenant, user_ref: user_ref,
          explain: explain.present? }
      end

      def timeline_label
        sql.to_s.first(120)
      end
    end
  end
end
