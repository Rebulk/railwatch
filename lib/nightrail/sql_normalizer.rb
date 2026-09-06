# frozen_string_literal: true

module Nightrail
  # Turns a SQL string into its shape so identical queries with different
  # literals group together. Adapter-aware where syntax differs (SQLite,
  # Postgres, MySQL/Trilogy).
  module SqlNormalizer
    IN_LIST = /\bIN\s*\(\s*(?:\?|\$\d+|\d+)(?:\s*,\s*(?:\?|\$\d+|\d+))*\s*\)/i
    WHITESPACE = /\s+/
    LITERAL_PREFIX_BYTES = [ 66, 69, 78, 88, 98, 101, 110, 120 ].freeze # B, E, N, X (both cases)
    BASE_PREFIX_BYTES = [ 66, 79, 88, 98, 111, 120 ].freeze # B, O, X (both cases)

    # Query payloads are eventually capped at 16,384 characters. Scan enough
    # bytes to preserve substantially more diagnostic shape than can be sent,
    # but never let a hostile or accidentally enormous SQL comment monopolize
    # the notification thread. The scanner below is byte-oriented and linear.
    MAX_NORMALIZE_BYTES = 262_144
    MAX_CACHE_KEY_BYTES = 65_536
    TRUNCATED = " [SQL TRUNCATED]"

    CACHE_LIMIT = 2_048
    # Three-level cache (adapter => connection_name => SQL => value) avoids a
    # composite-key allocation on every query. Adapter is part of the lookup:
    # identical SQL can mean a quoted identifier on Postgres and a string
    # literal on MySQL, so sharing a cached normalization would leak values.
    @cache = Hash.new { |adapters, adapter| adapters[adapter] = Hash.new { |connections, name| connections[name] = {} } }
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
      unless sql.is_a?(String) && sql.bytesize <= MAX_CACHE_KEY_BYTES
        normalized = normalize(sql, adapter: adapter).freeze
        return [ Record.group_hash(connection_name, normalized).freeze, normalized ].freeze
      end

      bucket = @cache[adapter.to_s][connection_name]
      cached = bucket[sql]
      return cached if cached

      normalized = normalize(sql, adapter: adapter).freeze
      value = [ Record.group_hash(connection_name, normalized).freeze, normalized ].freeze
      @cache_mutex.synchronize do
        bucket.clear if bucket.size >= CACHE_LIMIT
        bucket[sql] = value
      end
      value
    end

    def normalize(sql, adapter: nil)
      input, truncated = safe_utf8_prefix(sql, MAX_NORMALIZE_BYTES)
      s = mask_literals_and_comments(input, adapter: adapter)
      s = s.gsub(IN_LIST, "IN (?)")
      s = s.gsub(WHITESPACE, " ").strip
      truncated ? "#{s}#{TRUNCATED}" : s
    end

    # Returns a valid UTF-8 prefix without transcoding an unbounded input. A
    # byteslice may end inside a multibyte codepoint; scrub/encode replaces that
    # incomplete tail rather than letting observability raise while unwinding a
    # database error.
    def safe_utf8_prefix(value, max_bytes)
      string = value.to_s
      truncated = string.bytesize > max_bytes
      prefix = truncated ? string.byteslice(0, max_bytes) : string
      utf8 = if prefix.encoding == Encoding::UTF_8
        prefix.scrub
      else
        prefix.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
      end
      [ utf8, truncated ]
    rescue EncodingError
      [ prefix.to_s.b.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�"), truncated ]
    end

    # Safe text for the explicit raw-value mode. It is still bounded and valid
    # UTF-8 so malformed driver strings cannot break JSON generation.
    def raw_for_record(sql, max_characters:)
      text, = safe_utf8_prefix(sql, max_characters * 4)
      text[0, max_characters]
    end

    # A byte-oriented lexical pass keeps the cold/dynamic query path linear for
    # UTF-8 and malformed encodings. It masks values and comments while keeping
    # useful SQL shape. Unterminated value tokens fail closed.
    def mask_literals_and_comments(sql, adapter: nil)
      adapter_name = adapter.to_s.downcase
      mysql = adapter_name.include?("mysql") || adapter_name.include?("trilogy")
      # PostgreSQL-compatible adapters do not all expose "postgres" in
      # adapter_name. In particular activerecord-postgis-adapter reports
      # "PostGIS", and CockroachDB adapters commonly report "CockroachDB".
      postgres = adapter_name.include?("postgres") || adapter_name.include?("postgis") ||
        adapter_name.include?("cockroach")
      sqlite = adapter_name.include?("sqlite")
      unknown_adapter = !mysql && !postgres && !sqlite
      mysql_ambiguous = mysql || unknown_adapter
      bytes = sql.b
      length = bytes.bytesize
      out = +"".b
      i = 0

      while i < length
        byte = bytes.getbyte(i)
        following = bytes.getbyte(i + 1)
        if (byte == 45 && following == 45) || (mysql_ambiguous && byte == 35) # -- or MySQL #
          i += (byte == 35 ? 1 : 2)
          i += 1 while i < length && bytes.getbyte(i) != 10 && bytes.getbyte(i) != 13
          out << " "
        elsif byte == 47 && following == 42 # /*
          depth = 1
          i += 2
          while i < length && depth.positive?
            if bytes.getbyte(i) == 47 && bytes.getbyte(i + 1) == 42
              depth += 1
              i += 2
            elsif bytes.getbyte(i) == 42 && bytes.getbyte(i + 1) == 47
              depth -= 1
              i += 2
            else
              i += 1
            end
          end
          out << " "
        elsif byte == 39 # '
          # E'', N'', B'', and X'' are value introducers rather than part of
          # the query shape. Other introducers (for example _utf8mb4'') stay
          # visible, but their contents are still hidden.
          prefix = literal_prefix_byte(bytes, i)
          out.chop! if prefix
          explicit_escape_string = prefix == 69 || prefix == 101
          # Whether a backslash escapes the quote after it is a per-dialect
          # default the notification does not carry: MySQL escapes (unless the
          # session sets NO_BACKSLASH_ESCAPES), PostgreSQL does not (unless it
          # sets standard_conforming_strings off, deprecated since 9.1), E''
          # always does, SQLite never does. Scan with each dialect's default,
          # and treat an unknown adapter as MySQL-like -- getting that wrong
          # only masks more than necessary, while the other way round exposes
          # the tail of the value currently being masked.
          #
          # This deliberately no longer abandons the rest of the statement on
          # seeing \'. That was safe but destroyed the shape, and on MySQL --
          # where backslash escaping IS the quoting Active Record emits --
          # every string containing an apostrophe truncated the statement, so
          # `... WHERE name = 'O\'Brien' AND id = 1` and `... AND state = 'x'`
          # hashed into one query group. Values are masked either way; only
          # the tail's shape was being thrown away.
          backslash_escapes = mysql || unknown_adapter || explicit_escape_string
          i += 1
          while i < length
            if backslash_escapes && bytes.getbyte(i) == 92
              i += 2
            elsif bytes.getbyte(i) == 39
              if bytes.getbyte(i + 1) == 39
                i += 2
              else
                i += 1
                break
              end
            else
              i += 1
            end
          end
          out << "?"
        # When adapter metadata is unavailable, privacy wins over preserving
        # ANSI quoted-identifier shape: this may be a MySQL-compatible string.
        elsif mysql_ambiguous && byte == 34 # MySQL/Trilogy default: "..." is a string.
          i = skip_quoted_value(bytes, i, 34, backslash_escapes: true)
          out << "?"
        elsif sqlite && byte == 34 # SQLite DQS is ambiguous; mask unless syntax proves identifier use.
          close_at = quoted_identifier_end(bytes, i, 34)
          if close_at && sqlite_identifier_position?(bytes, i, close_at)
            out << bytes.byteslice(i, close_at - i)
          else
            out << "?"
          end
          i = close_at || length
        elsif byte == 34 || byte == 96 || (sqlite && byte == 91) # ANSI, backtick, or SQLite [identifier]
          closer = byte == 91 ? 93 : byte
          close_at = quoted_identifier_end(bytes, i, closer)
          if close_at
            out << bytes.byteslice(i, close_at - i)
            i = close_at
          else
            out << "?"
            i = length
          end
        elsif byte == 36 && (delimiter_end = dollar_delimiter_end(bytes, i))
          delimiter = bytes.byteslice(i, delimiter_end - i)
          close_at = bytes.index(delimiter, delimiter_end)
          i = close_at ? close_at + delimiter.bytesize : length
          out << "?"
        elsif byte == 36 && digit?(following) # PostgreSQL/SQLite $1 bind
          i += 2
          i += 1 while digit?(bytes.getbyte(i))
          out << "?"
        elsif byte == 63 && digit?(following) # SQLite ?NNN bind
          i += 2
          i += 1 while digit?(bytes.getbyte(i))
          out << "?"
        elsif numeric_boundary?(bytes, i) && (number_end = numeric_end(bytes, i))
          out << "?"
          i = number_end
        else
          out << byte
          i += 1
        end
      end

      out.force_encoding(Encoding::UTF_8)
    end

    def skip_quoted_value(bytes, index, quote, backslash_escapes:)
      length = bytes.bytesize
      i = index + 1
      while i < length
        if backslash_escapes && bytes.getbyte(i) == 92
          i += 2
        elsif bytes.getbyte(i) == quote
          if bytes.getbyte(i + 1) == quote
            i += 2
          else
            return i + 1
          end
        else
          i += 1
        end
      end
      length
    end

    def quoted_identifier_end(bytes, index, closer)
      length = bytes.bytesize
      i = index + 1
      while i < length
        if bytes.getbyte(i) == closer
          if bytes.getbyte(i + 1) == closer
            i += 2
          else
            return i + 1
          end
        else
          i += 1
        end
      end
      nil
    end

    SQLITE_IDENTIFIER_PRECEDERS = %w[as alter create delete drop from index into join table trigger update vacuum].freeze

    # SQLite retains a legacy double-quoted-string fallback when a token does
    # not resolve as an identifier. Qualification and object-name grammar are
    # unambiguous; a bare expression token is not, so privacy wins and it is
    # masked. Rails-generated `"table"."column"` and `FROM "table"` keep their
    # diagnostic value.
    def sqlite_identifier_position?(bytes, opening, after_closing)
      before = previous_nonspace(bytes, opening - 1)
      after = next_nonspace(bytes, after_closing)
      return true if before && bytes.getbyte(before) == 46
      return true if after && bytes.getbyte(after) == 46

      word = previous_word(bytes, opening - 1)
      SQLITE_IDENTIFIER_PRECEDERS.include?(word)
    end

    def previous_nonspace(bytes, index)
      index -= 1 while index >= 0 && whitespace_byte?(bytes.getbyte(index))
      index >= 0 ? index : nil
    end

    def next_nonspace(bytes, index)
      length = bytes.bytesize
      index += 1 while index < length && whitespace_byte?(bytes.getbyte(index))
      index < length ? index : nil
    end

    def previous_word(bytes, index)
      finish = previous_nonspace(bytes, index)
      return nil unless finish
      start = finish
      start -= 1 while start >= 0 && ascii_identifier_byte?(bytes.getbyte(start))
      bytes.byteslice(start + 1, finish - start).downcase
    end

    def dollar_delimiter_end(bytes, index)
      following = bytes.getbyte(index + 1)
      return index + 2 if following == 36
      # PostgreSQL dollar-quote tags follow unquoted-identifier rules, whose
      # letters include non-ASCII characters. The input is valid UTF-8 by the
      # time it reaches this scanner. Treat every high byte conservatively as
      # an identifier byte: accepting a little more than PostgreSQL does can
      # only hide extra text, while rejecting a valid tag can expose its body.
      return nil unless ascii_letter?(following) || following == 95 || non_ascii_byte?(following)

      i = index + 2
      i += 1 while ascii_identifier_byte?(bytes.getbyte(i)) || non_ascii_byte?(bytes.getbyte(i))
      bytes.getbyte(i) == 36 ? i + 1 : nil
    end

    def literal_prefix_byte(bytes, quote_index)
      return nil if quote_index.zero?
      prefix = bytes.getbyte(quote_index - 1)
      return nil unless LITERAL_PREFIX_BYTES.include?(prefix)
      return prefix if quote_index == 1
      ascii_identifier_byte?(bytes.getbyte(quote_index - 2)) || bytes.getbyte(quote_index - 2) == 36 ? nil : prefix
    end

    def numeric_end(bytes, index)
      length = bytes.bytesize
      i = index
      i += 1 if bytes.getbyte(i) == 45
      return nil if i >= length

      base_prefix = bytes.getbyte(i + 1)
      if bytes.getbyte(i) == 48 && BASE_PREFIX_BYTES.include?(base_prefix)
        base = base_prefix
        i += 2
        digits_start = i
        i += 1 while base_digit_or_underscore?(bytes.getbyte(i), base)
        return i > digits_start ? i : nil
      end

      digits = false
      while digit?(bytes.getbyte(i)) || bytes.getbyte(i) == 95
        digits ||= digit?(bytes.getbyte(i))
        i += 1
      end
      if bytes.getbyte(i) == 46
        i += 1
        while digit?(bytes.getbyte(i)) || bytes.getbyte(i) == 95
          digits ||= digit?(bytes.getbyte(i))
          i += 1
        end
      end
      return nil unless digits

      if bytes.getbyte(i) == 69 || bytes.getbyte(i) == 101
        exponent = i
        i += 1
        i += 1 if bytes.getbyte(i) == 43 || bytes.getbyte(i) == 45
        exponent_digits = false
        while digit?(bytes.getbyte(i)) || bytes.getbyte(i) == 95
          exponent_digits ||= digit?(bytes.getbyte(i))
          i += 1
        end
        i = exponent unless exponent_digits
      end
      i
    end

    def base_digit_or_underscore?(byte, base)
      return true if byte == 95
      case base
      when 88, 120 then digit?(byte) || (byte && ((65..70).cover?(byte) || (97..102).cover?(byte)))
      when 66, 98 then byte == 48 || byte == 49
      when 79, 111 then byte && (48..55).cover?(byte)
      else false
      end
    end

    def numeric_boundary?(bytes, index)
      byte = bytes.getbyte(index)
      return false unless digit?(byte) || byte == 46 || byte == 45
      return true if index.zero?

      previous = bytes.getbyte(index - 1)
      !ascii_identifier_byte?(previous) && previous != 36 && previous != 46
    end

    def digit?(byte)
      byte && (48..57).cover?(byte)
    end

    def ascii_letter?(byte)
      byte && ((65..90).cover?(byte) || (97..122).cover?(byte))
    end

    def ascii_identifier_byte?(byte)
      ascii_letter?(byte) || digit?(byte) || byte == 95
    end

    def non_ascii_byte?(byte)
      byte && byte >= 128
    end

    def whitespace_byte?(byte)
      byte == 32 || (byte && (9..13).cover?(byte))
    end
  end
end
