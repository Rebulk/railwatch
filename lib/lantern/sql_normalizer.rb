# frozen_string_literal: true

module Lantern
  # Turns a SQL string into its shape so identical queries with different
  # literals group together. Adapter-aware where syntax differs (SQLite,
  # Postgres, MySQL/Trilogy).
  module SqlNormalizer
    STRING = /'(?:[^']|'')*'/
    DOUBLE_QUOTED_STRING = /"(?:[^"]|"")*"/ # MySQL only
    NUMBER = /\b-?\d+(?:\.\d+)?\b/
    IN_LIST = /\bIN\s*\(\s*(?:\?|\$\d+|\d+)(?:\s*,\s*(?:\?|\$\d+|\d+))*\s*\)/i
    PG_BIND = /\$\d+/
    WHITESPACE = /\s+/
    COMMENT = %r{/\*.*?\*/|--[^\n]*}m

    CACHE_LIMIT = 2_048
    # Two-level cache (connection_name => { sql => [group_hash, normalized] })
    # avoids building an interpolated "#{connection_name}\0#{sql}" key string
    # on every query; almost every process only ever sees one connection_name,
    # so the outer lookup is a single cheap hash hit.
    @cache = Hash.new { |h, k| h[k] = {} }
    @cache_mutex = Mutex.new

    module_function

    # Same SQL text always maps to the same group, so the regex passes and the
    # digest run once per distinct statement per process.
    def group(sql, adapter: nil, connection_name: nil)
      group_and_normalized(sql, adapter: adapter, connection_name: connection_name)[0]
    end

    # Returns [group_hash, normalized_sql] from a single cache lookup, so
    # callers that need both (the query record and its possible n+1 sibling)
    # never normalize or digest the same SQL twice.
    def group_and_normalized(sql, adapter: nil, connection_name: nil)
      bucket = @cache[connection_name]
      cached = bucket[sql]
      return cached if cached

      normalized = normalize(sql, adapter: adapter)
      value = [ Record.group_hash(connection_name, normalized), normalized ].freeze
      @cache_mutex.synchronize do
        bucket.clear if bucket.size >= CACHE_LIMIT
        bucket[sql] = value
      end
      value
    end

    def normalize(sql, adapter: nil)
      s = sql.gsub(COMMENT, " ")
      s = s.gsub(STRING, "?")
      s = s.gsub(DOUBLE_QUOTED_STRING, "?") if adapter.to_s.match?(/mysql|trilogy/)
      s = s.gsub(PG_BIND, "?")
      s = s.gsub(NUMBER, "?")
      s = s.gsub(IN_LIST, "IN (?)")
      s.gsub(WHITESPACE, " ").strip
    end
  end
end
