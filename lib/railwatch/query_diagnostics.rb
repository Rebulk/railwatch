# frozen_string_literal: true

require "strscan"
require "railwatch/sql_normalizer"

module Railwatch
  # Read-only advice from captured evidence. This object has no database
  # connection, never executes SQL, and deliberately does not emit DDL.
  class QueryDiagnostics
    MAX_SQL_BYTES = 16_384
    MAX_PLAN_BYTES = 32_768
    MAX_PLAN_LINES = 200
    MAX_FINDINGS = 12
    MAX_EVIDENCE_BYTES = 1_000

    def self.call(**attributes) = new(**attributes).call

    def self.text(value, limit)
      SqlNormalizer.safe_utf8_prefix(value, limit).first
    end

    def self.bounded_plan(value)
      prefix, truncated = SqlNormalizer.safe_utf8_prefix(value, MAX_PLAN_BYTES)
      lines = prefix.lines
      { plan: lines.first(MAX_PLAN_LINES).join, truncated: truncated || lines.size > MAX_PLAN_LINES }
    end

    def self.adapter_family(adapter)
      case adapter.to_s.downcase
      when /postgres|postgis|cockroach/ then :postgres
      when /mysql|trilogy|mariadb/ then :mysql
      when /sqlite/ then :sqlite
      end
    end

    def initialize(sql:, adapter:, connection:, source: nil, plan: nil, n_plus_one: nil)
      @raw_sql = sql.to_s
      @adapter = self.class.text(adapter, 80)
      @connection = self.class.text(connection, 160)
      @source = self.class.text(source, 500)
      @family = self.class.adapter_family(@adapter)
      @plan = plan
      @n_plus_one = n_plus_one
      @recommendations = []
      @limitations = [ "Schema and index inventory are not available for this captured query. Index candidates may already exist; verify them on the source database." ]
    end

    def call
      status = analyze_sql
      analyze_plan
      analyze_repetition
      @limitations << "Only the first #{MAX_FINDINGS} findings are shown." if @recommendations.size > MAX_FINDINGS
      { status: status, adapter: @adapter, connection: @connection, source: @source,
        limitations: @limitations.uniq, recommendations: @recommendations.sort_by.with_index { |r, index| [ %w[capture plan sql].index(r[:basis]), index ] }.first(MAX_FINDINGS) }
    end

    private

    def analyze_sql
      if @raw_sql.empty?
        @limitations << "No SQL sample was captured in this window."
        return "unavailable"
      end
      unless @family
        @limitations << "SQL index candidates are unavailable for this adapter."
        return "unsupported"
      end
      if @raw_sql.bytesize > MAX_SQL_BYTES
        @limitations << "SQL exceeds the analysis limit; no index candidates were inferred from a partial statement."
        return "limited"
      end
      if @family == :mysql && @raw_sql.include?("/*!")
        @limitations << "Executable SQL comments require manual review; their server-version-dependent clauses were not interpreted."
        return "unsupported"
      end

      # Normalize old raw-value samples too. Comments and literals must never
      # be interpreted as identifiers or predicates.
      sql = SqlNormalizer.normalize(@raw_sql, adapter: @adapter)
      shape = SqlShape.new(sql, family: @family).call
      unless shape
        @limitations << "This SQL shape is outside the supported subset. Expressions, ambiguous columns, subqueries and disjunctions need manual review."
        return "unsupported"
      end
      if shape.size > 1 && shape.any? { |t| t[:order].any? }
        @limitations << "Join order can prevent an index's ordering from satisfying ORDER BY across joined tables."
      end
      shape.each { |table| index_candidate(table) }
      "analyzed"
    end

    def index_candidate(table)
      equality = table[:equality].uniq { |c| c[:key] }
      ranges = table[:range].uniq { |c| c[:key] }.reject { |c| equality.any? { |e| e[:key] == c[:key] } }
      order = table[:order].uniq { |c| c[:key] }.reject { |c| equality.any? { |e| e[:key] == c[:key] } }
      return if equality.empty? && ranges.empty? && order.empty?
      # A lone id lookup is normally a primary-key lookup. Without schema
      # evidence it is too weak a reason to recommend an index review.
      return if ranges.empty? && order.empty? && equality.one? && equality.first[:name].downcase == "id"

      columns = equality.map { |c| c[:column] }
      if ranges.one?
        columns << ranges.first[:column]
      elsif ranges.size > 1
        @limitations << "Multiple range predicates on #{table[:name]} need selectivity measurements before choosing an index order."
      end
      # Multiple independent ranges or a range on a different key cannot
      # support an ORDER BY suffix merely by appending its columns.
      order_compatible = ranges.empty? || (ranges.one? && !ranges.first[:membership] && order.first&.dig(:key) == ranges.first[:key])
      columns.concat(order.reject { |o| ranges.any? { |r| r[:key] == o[:key] } }.map { |c| c[:column] }) if order_compatible
      columns.uniq!
      return if columns.empty?
      entries = equality + ranges + order
      reasons = []
      reasons << "equality filters or join keys (#{equality.map { |c| c[:column] }.join(', ')})" if equality.any?
      reasons << "a #{ranges.first[:membership] ? 'membership' : 'range'} filter (#{ranges.first[:column]})" if ranges.one?
      reasons << "the ordering (#{order.map { |c| "#{c[:column]} #{c[:direction]}" }.join(', ')})" if order.any? && order_compatible
      add(id: "index_#{@recommendations.length}", kind: "index", basis: "sql",
        title: "Review #{columns.size > 1 ? 'a composite index' : 'index coverage'} on #{table[:name]}",
        explanation: "The SQL uses #{reasons.join(' with ')}. An index using #{columns.join(', ')} may help if this query is selective and frequently executed. The column order is a candidate, not a verified index definition.",
        action: "Compare existing indexes and column selectivity on this connection. Validate the leading equality keys, range position and sort directions with a representative plan; weigh write and storage costs before changing the schema.",
        table: table[:name], columns: columns,
        evidence: entries.uniq { |c| c[:evidence] }.first(6).map { |c| { source: "sql", text: c[:evidence] } })
    end

    def analyze_plan
      unless @plan && !@plan[:plan].to_s.empty?
        @limitations << "No stored EXPLAIN plan is available; SQL candidates do not describe the database's chosen plan."
        return
      end
      family = self.class.adapter_family(@plan[:adapter])
      unless family
        @limitations << "The stored plan's adapter is unknown; its text is shown without interpreting adapter-specific operations."
        return
      end
      bounded = self.class.bounded_plan(@plan[:plan])
      lines = bounded[:plan].lines
      if @plan[:truncated] || bounded[:truncated]
        @limitations << "Only the first #{MAX_PLAN_BYTES} bytes and #{MAX_PLAN_LINES} lines of the stored plan were inspected."
      end
      @limitations << "Plan observations apply to one captured sample. Estimates, table size and parameter values can change the chosen plan; a scan or sort does not prove an index is missing."
      mysql_columns = nil
      lines.each_with_index do |line, index|
        row = line.strip
        kind = nil
        case family
        when :postgres
          kind = :scan if row.match?(/\A(?:->\s*)?(?:Parallel\s+)?Seq Scan on\s/i)
          kind = :sort if row.match?(/\A(?:->\s*)?(?:Incremental\s+)?Sort(?:\s+\(|\z)/i)
          kind = :spill if row.match?(/\ASort Method:\s+external\b/i)
        when :sqlite
          kind = :scan if row.match?(/(?:\A|\|\s*|\d\s+)SCAN\s+(?!CONSTANT\b|\(subquery)/i) && !row.match?(/\bUSING\s+(?:COVERING\s+)?INDEX\b/i)
          kind = :sort if row.match?(/\bUS(?:E|ING) TEMP B-TREE FOR (?:ORDER BY|GROUP BY|DISTINCT)\b/i)
        when :mysql
          cells = row.start_with?("|") && row.end_with?("|") ? row[1...-1].split("|", -1).map(&:strip) : []
          if cells.include?("type") && cells.include?("table")
            mysql_columns = cells
            next
          end
          fields = mysql_columns && cells.size == mysql_columns.size ? mysql_columns.zip(cells).to_h : {}
          kind = :scan if fields["type"] == "ALL" || row.match?(/\A(?:table:\s*\S+\s+)?type:\s*ALL\b/i)
          plan_finding(:sort, line, index + 1) if fields["Extra"].to_s.match?(/\bUsing filesort\b/i) || row.match?(/\A(?:type:\s*\w+\s+)?Extra:\s*.*\bUsing filesort\b/i)
        end
        plan_finding(kind, line, index + 1) if kind
        break if @recommendations.count { |r| r[:basis] == "plan" } >= 6
      end
    end

    def plan_finding(kind, line, number)
      return if @recommendations.count { |r| r[:basis] == "plan" } >= 6
      title, explanation, action = case kind
      when :scan
        [ "Scan in the captured plan",
          "The stored plan reports a scan. The optimizer can choose this even when an index exists, especially for small tables or predicates matching many rows.",
          "Compare estimated rows with table size and filter selectivity. Check existing indexes and statistics before deciding whether a different access path would help." ]
      when :sort
        [ "Sort work in the captured plan",
          "The stored plan reports a sort or temporary B-tree. This records the chosen operation; it does not establish its runtime cost or whether an index can avoid it.",
          "Review ORDER BY, grouping and join order with the full plan. A compatible index may help, but the optimizer can still prefer sorting." ]
      when :spill
        [ "Disk sort in the captured plan",
          "The stored plan reports an external sort method, which uses disk for this sample.",
          "Review input row counts, selected columns and sort keys. Compare memory settings and index options in a representative environment before tuning." ]
      end
      add(id: "plan_#{kind}_#{number}", kind: kind.to_s, basis: "plan", title: title, explanation: explanation, action: action,
        evidence: [ { source: "plan", text: line.chomp, line: number } ])
    end

    def analyze_repetition
      return unless @n_plus_one
      suggestion = @n_plus_one[:suggestion]
      add(id: "repeated_query", kind: "n_plus_one", basis: "capture", title: "Repeated query captured",
        explanation: "A captured N+1 sample recorded this query shape #{@n_plus_one[:count].to_i} times in one execution. Review its caller for repeated association loads.",
        action: suggestion ? "#{suggestion[:explanation]} Verify the inferred association names and loading semantics before applying this Rails example." : "Review the calling loop and association loading. Preloading, batching or a counter cache may reduce repeated work depending on the query.",
        code: suggestion && suggestion[:code], evidence: [ { source: "n_plus_one", text: @n_plus_one[:sql].to_s },
          { source: "source", text: @n_plus_one[:source].to_s } ].reject { |e| e[:text].empty? })
    end

    def add(**finding)
      finding[:evidence].each do |e|
        original = e[:text].to_s
        e[:text] = self.class.text(original, MAX_EVIDENCE_BYTES)
        e[:truncated] = original.bytesize > MAX_EVIDENCE_BYTES
      end
      finding[:action] = self.class.text(finding[:action], 2_000)
      finding[:code] = self.class.text(finding[:code], 2_000) if finding[:code]
      @recommendations << finding
    end

    # A deliberately small grammar, not a general SQL parser. It accepts
    # simple SELECTs with explicit joins, AND predicates and plain sort keys.
    # Anything ambiguous fails closed rather than fabricating identifiers.
    class SqlShape
      MAX_TOKENS = 2_000
      RESERVED = %w[SELECT FROM WHERE JOIN LEFT RIGHT FULL INNER OUTER CROSS ON AS ORDER BY LIMIT OFFSET AND OR NOT IN IS NULL TRUE FALSE ASC DESC GROUP HAVING UNION EXCEPT INTERSECT WITH DISTINCT FOR WINDOW USING COLLATE].freeze
      JOIN_WORDS = %w[JOIN LEFT RIGHT FULL INNER OUTER].freeze

      def initialize(sql, family:)
        @sql = sql
        @family = family
        @tables = []
        @aliases = {}
      end

      def call
        @tokens = tokenize
        return unless @tokens && @tokens.first&.dig(:word) == "SELECT"
        return if @tokens.count { |t| t[:word] == "SELECT" } != 1
        @tokens.pop if @tokens.last&.dig(:raw) == ";"
        return if @tokens.any? { |t| t[:raw] == ";" || %w[WITH UNION EXCEPT INTERSECT GROUP HAVING DISTINCT FOR WINDOW OR NOT COLLATE].include?(t[:word]) }
        from = @tokens.index { |t| t[:word] == "FROM" }
        return unless from && from > 1
        @cursor = from + 1
        return unless table_reference
        predicates = []
        while JOIN_WORDS.include?(word)
          advance while %w[LEFT RIGHT FULL INNER OUTER].include?(word)
          return unless take("JOIN") && table_reference && take("ON")
          predicates << take_until(JOIN_WORDS + %w[WHERE ORDER LIMIT OFFSET])
        end
        predicates << take_until(%w[ORDER LIMIT OFFSET]) if take("WHERE")
        return unless predicates.all? { |p| parse_predicates(p) }
        if take("ORDER")
          return unless take("BY") && parse_order(take_until(%w[LIMIT OFFSET]))
        end
        %w[LIMIT OFFSET].each do |keyword|
          next unless take(keyword)
          return unless value?(@tokens[@cursor])
          advance
        end
        return unless @cursor == @tokens.length
        @tables
      end

      private

      def tokenize
        scanner = StringScanner.new(@sql)
        tokens = []
        until scanner.eos?
          break if tokens.length >= MAX_TOKENS
          next if scanner.scan(/\s+/)
          start = scanner.pos
          raw = scanner.scan(/"(?:[^"]|"")*"|`(?:[^`]|``)*`|\[(?:[^\]]|\]\])*\]/)
          if raw
            return if (@family == :mysql && raw.start_with?('"')) || (@family == :postgres && !raw.start_with?('"'))
            name = raw[1...-1].gsub(raw[-1] * 2, raw[-1])
            token = { identifier: true, name: name, key: @family == :postgres ? name : name.downcase }
          elsif (raw = scanner.scan(/[A-Za-z_][A-Za-z_0-9$]*/))
            token = { word: raw.upcase, identifier: !RESERVED.include?(raw.upcase), name: raw, key: raw.downcase }
          elsif (raw = scanner.scan(/\?\d*|\$\d+|[:@][A-Za-z_]\w*|\d+(?:\.\d+)?/))
            token = { value: true }
          elsif (raw = scanner.scan(/>=|<=|<>|!=|[=<>.,()*;+-]/))
            token = {}
          else
            return
          end
          tokens << token.merge(raw: raw, start: start, finish: scanner.pos)
        end
        tokens if scanner.eos?
      end

      def word = @tokens[@cursor]&.dig(:word)
      def advance = @cursor += 1
      def take(keyword)
        return false unless word == keyword
        advance
        true
      end

      def reference(tokens, offset = 0)
        parts = []
        cursor = offset
        loop do
          token = tokens[cursor]
          return unless token && token[:identifier]
          parts << token
          cursor += 1
          break unless tokens[cursor]&.dig(:raw) == "."
          cursor += 1
          return if parts.size >= 3
        end
        [ parts, cursor ]
      end

      def table_reference
        parsed = reference(@tokens, @cursor)
        return unless parsed
        parts, @cursor = parsed
        return if parts.size > 2 || @tables.size >= 6
        name = parts.map { |p| p[:raw] }.join(".")
        key = parts.map { |p| p[:key] }
        return if @tables.any? { |t| t[:key] == key }
        alias_token = nil
        if take("AS")
          return unless @tokens[@cursor]&.dig(:identifier)
          alias_token = @tokens[@cursor]
          advance
        elsif @tokens[@cursor]&.dig(:identifier)
          alias_token = @tokens[@cursor]
          advance
        end
        table = { name: name, key: key, equality: [], range: [], order: [] }
        keys = alias_token ? [ [ alias_token[:key] ] ] : [ key, [ parts.last[:key] ] ].uniq
        return if keys.any? { |k| @aliases.key?(k) }
        keys.each { |k| @aliases[k] = table }
        @tables << table
        true
      end

      def take_until(keywords)
        start = @cursor
        advance while @cursor < @tokens.length && !keywords.include?(word)
        @tokens[start...@cursor]
      end

      def parse_predicates(tokens)
        return false if tokens.empty?
        # Parentheses may only group AND terms; IN has its own parentheses.
        # Removing balanced outer groups is safe after rejecting OR/NOT.
        depth = 0
        terms = [ [] ]
        tokens.each do |token|
          depth += 1 if token[:raw] == "("
          depth -= 1 if token[:raw] == ")"
          return false unless depth.between?(0, 24)
          token[:word] == "AND" ? terms << [] : terms.last << token
        end
        return false unless depth.zero?
        terms.all? do |term|
          term.shift while term.first&.dig(:raw) == "("
          # IN needs exactly one closing parenthesis; grouping needs none.
          keep = term.any? { |t| t[:word] == "IN" } ? 1 : 0
          term.pop while term.last&.dig(:raw) == ")" && term.count { |t| t[:raw] == ")" } > keep
          parse_predicate(term)
        end
      end

      def column(tokens)
        parsed = reference(tokens)
        return unless parsed && parsed.last == tokens.size
        parts = parsed.first
        table = parts.one? ? (@tables.first if @tables.one?) : @aliases[parts[0...-1].map { |p| p[:key] }]
        return unless table
        [ table, { column: parts.last[:raw], name: parts.last[:name], key: parts.last[:key] } ]
      end

      def parse_predicate(term)
        at = term.index { |t| %w[= > < >= <=].include?(t[:raw]) || %w[IN IS].include?(t[:word]) }
        return false unless at
        left = column(term[0...at])
        return false unless left
        op = term[at][:raw].upcase
        right = term[(at + 1)..]
        other = column(right)
        valid_value = op != "IS" && right.one? && value?(right.first)
        valid_null = op == "IS" && right.one? && right.first[:word] == "NULL"
        valid_in = op == "IN" && right.size == 3 && right[0][:raw] == "(" && value?(right[1]) && right[2][:raw] == ")"
        return false unless valid_value || valid_null || valid_in || (op == "=" && other && other.first != left.first)
        evidence = @sql.byteslice(term.first[:start]...term.last[:finish])
        kind = %w[= IS].include?(op) ? :equality : :range
        left.first[kind] << left.last.merge(evidence: evidence, membership: op == "IN")
        other.first[:equality] << other.last.merge(evidence: evidence) if other
        true
      end

      def parse_order(tokens)
        return false if tokens.empty?
        evidence = "ORDER BY #{@sql.byteslice(tokens.first[:start]...tokens.last[:finish])}"
        parts = [ [] ]
        tokens.each { |t| t[:raw] == "," ? parts << [] : parts.last << t }
        parts.all? do |part|
          direction = %w[ASC DESC].include?(part.last&.dig(:word)) ? part.pop[:word] : "ASC"
          col = column(part)
          next false unless col
          col.first[:order] << col.last.merge(direction: direction, evidence: evidence)
          true
        end
      end

      def value?(token) = token && (token[:value] || %w[TRUE FALSE].include?(token[:word]))
    end
  end
end
