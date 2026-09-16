# frozen_string_literal: true

module Telemetry
  class Log < TelemetryRecord
    include Child

    # Wraps each hit inside a snippet. One character for both ends so the
    # frontend can split on it and mark the odd-numbered pieces; U+001F is
    # not something a log line can realistically contain.
    SNIPPET_MARK = "\u001F"

    # "quoted phrase" | -excluded | bare, in the order they were typed.
    TERM = /-?"[^"]*"|\S+/

    scope :fts, ->(text) {
      next none if text.to_s.strip.empty?
      next where("message LIKE ?", "%#{sanitize_sql_like(text)}%") unless fts_available?
      match = match_expression(text)
      match ? where("logs.id IN (SELECT rowid FROM logs_fts WHERE logs_fts MATCH ?)", match) : none
    }

    class << self
      # Free text -> an FTS5 MATCH expression. Quoted phrases stay whole,
      # every other word becomes a prefix token so "widg" finds "widgets",
      # and a leading "-" excludes -- but only when something positive is
      # left to exclude from, since FTS5's NOT needs a left operand. Every
      # term is emitted as a quoted string, which is what keeps FTS5 syntax
      # (NEAR, *, :, parens) inert instead of raising a "syntax error".
      # Returns nil when the text has nothing searchable in it.
      def match_expression(text)
        terms = text.to_s.scan(TERM).filter_map { |term| parse_term(term) }
        positive = terms.reject(&:first).map(&:last)
        negative = terms.select(&:first).map(&:last)
        if positive.empty?
          positive = negative
          negative = []
        end
        return nil if positive.empty?
        [ positive.join(" "), *negative.map { |term| "NOT #{term}" } ].join(" ")
      end

      # id => message with SNIPPET_MARK around each hit, for the rows the
      # page is about to render. Empty unless we actually ran an FTS query.
      def fts_snippets(ids, text)
        return {} if ids.empty? || !fts_available?
        match = match_expression(text)
        return {} if match.nil?
        sql = sanitize_sql_array([ "SELECT rowid, snippet(logs_fts, 0, ?, ?, ?, 24) FROM logs_fts WHERE logs_fts MATCH ? AND rowid IN (?)",
          SNIPPET_MARK, SNIPPET_MARK, "…", match, ids ])
        connection.select_rows(sql).to_h
      end

      # Postgres telemetry databases (SCOPE.md keeps them supported) have no
      # logs_fts, and neither does a database created before the index was
      # added. Every telemetry database is built from the same schema, so
      # this is a process-wide fact rather than a per-environment one.
      def fts_available?
        return @fts_available if defined?(@fts_available)
        @fts_available = connection.adapter_name.match?(/sqlite/i) &&
          connection.select_value("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'logs_fts'").present?
      end

      private

      # "term" -> [negated?, fts5 term], or nil if there is nothing left of
      # it once the quotes and the minus sign come off.
      def parse_term(term)
        negated = term.start_with?("-") && term.length > 1
        body = negated ? term[1..] : term
        phrase = body.start_with?('"') && body.end_with?('"') && body.length > 1
        body = body[1..-2].to_s if phrase
        return nil unless body.match?(/[[:alnum:]]/)
        [ negated, phrase ? quote(body) : "#{quote(body)}*" ]
      end

      def quote(term) = %("#{term.gsub('"', '""')}")
    end

    def timeline_label
      message.to_s.first(120)
    end
  end
end
