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

    CACHE_LIMIT = 5_000
    @cache = {}
    @cache_mutex = Mutex.new

    module_function

    # Same SQL text always maps to the same group, so the regex passes and the
    # digest run once per distinct statement per process.
    def group(sql, adapter: nil, connection_name: nil)
      key = connection_name ? "#{connection_name}\0#{sql}" : sql
      cached = @cache[key]
      return cached if cached

      value = Record.group_hash(connection_name, normalize(sql, adapter: adapter))
      @cache_mutex.synchronize do
        @cache.clear if @cache.size >= CACHE_LIMIT
        @cache[key] = value
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
