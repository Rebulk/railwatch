# frozen_string_literal: true

module Railwatch
  module Telemetry
    class NPlusOne < TelemetryRecord
      include Child

      # A bound value in the SQL the gem stores. Railwatch::SqlNormalizer has
      # already rewritten literals to "?" and one-element IN lists to "IN (?)"
      # before an n+1 record is written; the bare-number branch only covers SQL
      # that reached us unnormalized.
      BIND = /(?:=\s*(?:\?|-?\d+)|IN\s*\(\s*(?:\?|-?\d+)\s*\))/i

      # Matched against `shape`, which strips identifier quoting so one set of
      # patterns covers SQLite/Postgres ("comments") and MySQL (`comments`).
      # POLYMORPHIC has to be tried before CHILD_LOAD: an imageable_id filter
      # matches both, and only the first one reads it as a polymorphic owner.
      POLYMORPHIC = /\ASELECT\s+(?:\w+\.)?\*\s+FROM\s+(\w+)\s+WHERE\s+(?:\w+\.)?(\w+)_id\s*#{BIND}\s+AND\s+(?:\w+\.)?\2_type\s*#{BIND}/i
      COUNT_LOAD = /\ASELECT\s+COUNT\(\*\)\s+(?:AS\s+\w+\s+)?FROM\s+(\w+)\s+WHERE\s+(?:\w+\.)?(\w+)_id\s*#{BIND}/i
      EXISTS_LOAD = /\ASELECT\s+(?:1\s+AS\s+one|EXISTS\s*\(\s*SELECT\s+1)\b.*?\sFROM\s+(\w+)\s+WHERE\s+(?:\w+\.)?(\w+)_id\s*#{BIND}/i
      CHILD_LOAD = /\ASELECT\s+(?:\w+\.)?\*\s+FROM\s+(\w+)\s+WHERE\s+(?:\w+\.)?(\w+)_id\s*#{BIND}/i
      PARENT_LOAD = /\ASELECT\s+(?:\w+\.)?\*\s+FROM\s+(\w+)\s+WHERE\s+(?:\w+\.)?id\s*#{BIND}/i

      def timeline_label
        sql.to_s.first(120)
      end

      # A concrete fix for the repeated statement, read off its SQL shape:
      # {kind:, parent:, association:, code:, explanation:}, or nil when the
      # statement isn't a shape a preload or counter cache can fix.
      def suggestion
        s = shape
        polymorphic_load(s) || count_load(s) || exists_load(s) || child_load(s) || parent_load(s)
      end

      private

      def shape
        sql.to_s.delete('"`').squeeze(" ").strip
      end

      def polymorphic_load(s)
        m = POLYMORPHIC.match(s) or return nil
        table, as = m[1], m[2]
        { kind: "polymorphic", parent: nil, association: table,
          code: ".includes(:#{table})",
          explanation: "Each owner loads its #{table} in a separate query. #{table} is polymorphic (belongs_to :#{as}), " \
                       "so add .includes(:#{table}) on the collection you iterate#{at_source}." }
      end

      def count_load(s)
        m = COUNT_LOAD.match(s) or return nil
        table, parent = m[1], m[2].classify
        { kind: "counter_cache", parent: parent, association: table,
          code: "# app/models/#{m[1].singularize}.rb\nbelongs_to :#{m[2]}, counter_cache: true\n\n# then read\n#{m[2]}.#{table}_count",
          explanation: "Each #{parent} counts its #{table} with its own COUNT query#{at_source}. " \
                       "A counter cache keeps the total on #{parent.tableize}.#{table}_count, so #{m[2]}.#{table}_count needs no query." }
      end

      def exists_load(s)
        m = EXISTS_LOAD.match(s) or return nil
        table, parent = m[1], m[2].classify
        { kind: "exists", parent: parent, association: table,
          code: "#{parent}.includes(:#{table})\n\n# then\n#{m[2]}.#{table}.any?",
          explanation: "Each #{parent} checks whether it has #{table} with its own query#{at_source}. " \
                       "Preload with #{parent}.includes(:#{table}) and call .any? on the loaded collection, or add a counter cache." }
      end

      def child_load(s)
        m = CHILD_LOAD.match(s) or return nil
        table, parent = m[1], m[2].classify
        { kind: "has_many", parent: parent, association: table,
          code: "#{parent}.includes(:#{table})",
          explanation: "Each #{parent} loads its #{table} in a separate query#{at_source}. " \
                       "Preload them with #{parent}.includes(:#{table}) where the #{parent.tableize} are loaded." }
      end

      def parent_load(s)
        m = PARENT_LOAD.match(s) or return nil
        association = m[1].singularize
        { kind: "belongs_to", parent: nil, association: association,
          code: ".includes(:#{association})",
          explanation: "Each row loads its #{association} one at a time. " \
                       "Add .includes(:#{association}) on the collection you iterate#{at_source}." }
      end

      def at_source
        source.present? ? " at #{source}" : ""
      end
    end
  end
end
