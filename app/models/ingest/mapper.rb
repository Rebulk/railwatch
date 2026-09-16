# frozen_string_literal: true

module Ingest
  # Maps a wire record (the gem's flat hash) to a plain row: [klass, attrs],
  # where attrs is a Hash of column name => value already serialized the way
  # SQLite wants it on the wire (JSON columns as JSON strings, times as UTC
  # "YYYY-MM-DD HH:MM:SS.ffffff" strings, booleans as 0/1, integers as
  # Integer, strings truncated to the column's limit). Building an AR
  # instance per record was measured at ~970ms of 1060ms for 300 records;
  # row_for skips that and lets Ingest::Writer bind straight into a prepared
  # statement.
  module Mapper
    PARENTS = %w[request job_attempt scheduled_task command channel_action].freeze

    # SQLite TEXT and JSON columns have no schema-level limit. These caps are
    # therefore part of the wire contract, not presentation limits: they stop
    # one valid 32 MiB request from becoming one equally large database cell.
    # JSON that exceeds its cap is replaced by a small valid marker object;
    # slicing encoded JSON could leave an invalid document in SQLite.
    TEXT_LIMITS = {
      "deprecations.message" => 65_536,
      "exceptions.cause" => 65_536,
      "exceptions.context" => 65_536,
      "exceptions.fingerprint" => 65_536,
      "exceptions.frames" => 262_144,
      "exceptions.locals" => 65_536,
      "exceptions.message" => 65_536,
      "executions.counters" => 65_536,
      "executions.detail" => 65_536,
      "executions.stages" => 65_536,
      "health_samples.detail" => 65_536,
      "llm_calls.completion" => 16_384,
      "llm_calls.params" => 16_384,
      "llm_calls.prompt" => 16_384,
      "logs.context" => 65_536,
      "logs.message" => 65_536,
      "logs.tags" => 65_536,
      "n_plus_ones.sql" => 16_384,
      "outgoing_requests.response_body" => 65_536,
      "processes.detail" => 65_536,
      "queries.explain" => 65_536,
      "queries.sql" => 16_384,
      "query_shapes.sql" => 16_384,
      "spans.payload" => 65_536,
      "visits.only" => 65_536
    }.freeze

    JSON_TRUNCATED = JSON.generate(truncated: true).freeze
    JSON_ARRAY_TRUNCATED = JSON.generate([ { truncated: true } ]).freeze
    INTEGER_MAX = (2**63) - 1
    INTEGER_MIN = -(2**63)
    # The gem sends UUIDs, but the wire contract only promises an opaque
    # identifier that fits the column, so any printable ASCII token is kept.
    IDENTIFIER = /\A[\x21-\x7e]{1,36}\z/
    GROUP_HASH = /\A[0-9a-f]{32}\z/i
    STRUCTURES = {
      "stages" => Hash, "counters" => Hash, "inertia" => Hash, "params" => Hash,
      "frames" => Array, "fingerprint" => Array, "tags" => Array,
      "only" => Array, "attributes" => Hash, "locals" => Hash
    }.freeze

    COLUMN_CACHE = {}
    SERIALIZATION_COLUMN_CACHE = {}
    COLUMN_CACHE_MUTEX = Mutex.new
    TIME_PREFIX_CACHE_KEY = :railwatch_ingest_time_prefixes
    TIME_PREFIX_CACHE_LIMIT = 64
    private_constant :COLUMN_CACHE, :SERIALIZATION_COLUMN_CACHE, :COLUMN_CACHE_MUTEX,
      :TIME_PREFIX_CACHE_KEY, :TIME_PREFIX_CACHE_LIMIT

    module_function

    # column name (String) => [type, limit, null, default], built once per
    # class and reused for every row of that class.
    def columns_for(klass)
      COLUMN_CACHE[klass] ||= COLUMN_CACHE_MUTEX.synchronize do
        COLUMN_CACHE[klass] ||= begin
          columns = {}
          serialization_columns = []
          klass.columns_hash.each_value do |column|
            metadata = [ column.type, column.limit, column.null, column.default ].freeze
            columns[column.name] = metadata
            serialization_columns << [ column.name.to_sym, *metadata ].freeze
          end
          SERIALIZATION_COLUMN_CACHE[klass] = serialization_columns.freeze
          columns.freeze
        end
      end
    end

    def serialization_columns_for(klass)
      columns_for(klass)
      SERIALIZATION_COLUMN_CACHE.fetch(klass)
    end
    private_class_method :serialization_columns_for

    def row_for(rec, truncations: nil, validate_identifiers: true)
      validate_record!(rec, identifiers: validate_identifiers)
      type = rec["t"].to_s
      pair = PARENTS.include?(type) ? execution(rec) : mapped(type, rec)
      return nil if pair.nil?
      klass, attrs = pair
      [ klass, serialize(klass, attrs, truncations: truncations) ]
    end

    def validate_record!(rec, identifiers: true)
      raise TypeError, "record must be an object" unless rec.is_a?(Hash)
      raise TypeError, "t must be a string" unless rec["t"].is_a?(String)

      if identifiers
        validate_identifier!(rec, "_group", GROUP_HASH, "32 hexadecimal characters")
        validate_identifier!(rec, "execution_id", IDENTIFIER, "a printable token of at most 36 characters")
        validate_identifier!(rec, "trace_id", IDENTIFIER, "a printable token of at most 36 characters")
      end
      STRUCTURES.each do |field, expected|
        value = rec[field]
        next if value.nil? || value.is_a?(expected)

        raise TypeError, "#{field} must be a #{expected.name.downcase}"
      end
      validate_numeric_hash!(rec["stages"], "stages")
      validate_numeric_hash!(rec["counters"], "counters")
      validate_frames!(rec["frames"])
      validate_locals!(rec["locals"])
    end

    def validate_identifier!(rec, field, pattern, description)
      value = rec[field]
      return if value.nil?
      raise TypeError, "#{field} must be #{description}" unless value.is_a?(String) && value.match?(pattern)
    end
    private_class_method :validate_identifier!

    def validate_numeric_hash!(value, field)
      return unless value
      return if value.all? { |key, number| key.is_a?(String) && number.is_a?(Numeric) && number.to_f.finite? && number >= 0 }

      raise TypeError, "#{field} must contain non-negative numbers"
    end
    private_class_method :validate_numeric_hash!

    def validate_frames!(frames)
      return unless frames
      valid = frames.all? do |frame|
        frame.is_a?(Hash) && %w[file function].all? { |field| frame[field].nil? || frame[field].is_a?(String) } &&
          (frame["line"].nil? || (frame["line"].is_a?(Integer) && frame["line"] >= 0)) &&
          (frame["in_app"].nil? || frame["in_app"] == true || frame["in_app"] == false) &&
          (frame["code"].nil? || (frame["code"].is_a?(Hash) &&
            frame["code"].all? { |line, source| line.is_a?(String) && source.is_a?(String) }))
      end
      raise TypeError, "frames must contain frame objects" unless valid
    end
    private_class_method :validate_frames!

    def validate_locals!(locals)
      return unless locals
      return if locals.all? { |key, value| key.is_a?(String) && !value.is_a?(Hash) && !value.is_a?(Array) }

      raise TypeError, "locals must contain scalar values"
    end
    private_class_method :validate_locals!

    # AR instance for callers that want validations, callbacks, or a normal
    # object (specs, anything that isn't the hot ingest path). row_for's
    # JSON columns come back pre-encoded as strings; the AR json type does
    # not parse a String on assignment, so they're inflated here.
    def build(rec)
      pair = row_for(rec)
      return nil if pair.nil?
      klass, attrs = pair
      cols = columns_for(klass)
      ar_attrs = attrs.each_with_object({}) do |(name, value), out|
        type, = cols[name.to_s]
        out[name] = type == :json && value.is_a?(String) ? JSON.parse(value) : value
      end
      klass.new(ar_attrs)
    end

    # Person writes use a purpose-built bulk upsert instead of row_for, but
    # the same trust-boundary rules still apply to their wire strings.
    def person_record(rec, validate_identifiers: true)
      validate_record!(rec, identifiers: validate_identifiers)
      {
        "id" => cast_value(rec["id"], :string, 255, klass: Telemetry::Person, name: :ref),
        "name" => cast_value(rec["name"], :string, 255, klass: Telemetry::Person, name: :name),
        "email" => cast_value(rec["email"], :string, 255, klass: Telemetry::Person, name: :email),
        "tenant" => cast_value(rec["tenant"], :string, 255, klass: Telemetry::Person, name: :app_tenant),
        "timestamp" => rec["timestamp"]
      }
    end

    def mapped(type, rec)
      case type
      when "query" then child(Telemetry::Query, rec, %w[sql name duration connection adapter role async in_transaction row_count source allocations explain])
      when "span" then span(rec)
      when "health" then health(rec)
      when "exception" then exception(rec)
      when "cache_event" then child(Telemetry::CacheEvent, rec, %w[store key type duration ttl hits])
      when "mail" then child(Telemetry::Mail, rec, %w[mailer subject to cc bcc attachments delivery_method perform_deliveries duration failed message_id])
      when "broadcast" then child(Telemetry::Broadcast, rec, %w[kind stream channel action bytes duration failed])
      when "notification" then child(Telemetry::Notification, rec, %w[notifier delivery_method channel duration failed])
      when "outgoing_request" then child(Telemetry::OutgoingRequest, rec, %w[host method url duration status_code request_size response_size error source response_body])
      when "llm_call" then child(Telemetry::LlmCall, rec, %w[operation provider model response_model tool_name duration status error
        streaming message_count tool_count input_tokens output_tokens cache_read_tokens cache_write_tokens thinking_tokens
        cost_nanos workflow_id workflow_name workflow_step_id workflow_step_name workflow_step_parent_id prompt completion
        finish_reason provider_request_id tools cost_reported attachments attachment_types attachment_names tool_call_id params])
      when "profile" then profile(rec)
      when "attachment" then attachment(rec)
      when "storage_op" then child(Telemetry::StorageOp, rec, %w[service op key duration])
      when "view_render" then child(Telemetry::ViewRender, rec, %w[identifier kind layout count cache_hits duration])
      when "log" then child(Telemetry::Log, rec, %w[level message tags context source])
      when "enqueued_job" then enqueued_job(rec)
      when "transaction" then child(Telemetry::Transaction, rec, %w[duration outcome connection statement_count])
      when "n_plus_one" then child(Telemetry::NPlusOne, rec, %w[sql count source])
      when "deprecation" then child(Telemetry::Deprecation, rec, %w[message gem_name horizon source])
      when "visit" then child(Telemetry::Visit, rec, %w[component url method duration status partial only props_bytes user_agent lcp cls inp ttfb])
      when "session" then session(rec)
      when "user" then [ Telemetry::Person, { ref: rec["id"].to_s } ] # replaced by touch_from_record; never saved as-is
      when "process" then process(rec)
      end
    end

    def envelope(rec)
      {
        occurred_at: timestamp_string(rec["timestamp"]),
        deploy: rec["deploy"],
        server: rec["server"],
        group_hash: rec["_group"],
        trace_id: rec["trace_id"],
        execution_source: rec["execution_source"],
        execution_id: rec["execution_id"],
        execution_preview: rec["execution_preview"],
        execution_stage: rec["execution_stage"],
        user_ref: rec["user"],
        app_tenant: rec["tenant"]
      }
    end

    def child(klass, rec, keys)
      attrs = envelope(rec)
      keys.each { |k| attrs[k.to_sym] = rec[k] }
      [ klass, attrs ]
    end

    def execution(rec)
      kind = rec["t"]
      name = case kind
      when "request" then "#{rec['method']} #{rec['route']}"
      when "command" then rec["command"] || rec["name"]
      when "scheduled_task" then rec["task_key"] || rec["name"]
      when "channel_action" then "#{rec['channel']}##{rec['action']}"
      else rec["name"]
      end
      detail_keys = case kind
      when "request" then %w[url path ip headers payload context user_agent view_runtime db_runtime redirect_to halted_callback unpermitted_parameters rate_limited format inertia request_size response_size gc_time]
      when "command" then %w[context gc_time interactive]
      when "channel_action" then %w[channel context gc_time]
      else %w[job_id provider_job_id attempt_id adapter priority db_runtime arguments_preview context gc_time schedule]
      end
      attrs = envelope(rec)
      attrs[:kind] = kind
      attrs[:name] = name.to_s
      attrs[:duration] = rec["duration"]
      attrs[:status] = rec["status_code"] || rec["exit_code"]
      attrs[:outcome] = rec["status"]
      attrs[:method] = rec["method"]
      attrs[:route] = rec["route"]
      attrs[:controller] = rec["controller"]
      attrs[:action] = rec["action"]
      attrs[:queue] = rec["queue"]
      attrs[:attempt] = rec["attempt"]
      attrs[:queue_latency] = rec["queue_latency"]
      attrs[:queue_time] = rec["queue_time"]
      attrs[:parent_id] = rec["parent_id"]
      attrs[:job_id] = rec["job_id"]
      attrs[:task_key] = rec["task_key"]
      attrs[:inertia_component] = rec.dig("inertia", "component")
      attrs[:inertia_partial] = rec.dig("inertia", "partial_only").present?
      attrs[:allocations] = rec["allocations"]
      attrs[:peak_memory] = rec["peak_memory"]
      attrs[:exception_preview] = rec["exception_preview"]
      attrs[:stages] = rec["stages"] || {}
      attrs[:counters] = rec["counters"] || {}
      attrs[:detail] = rec.slice(*detail_keys)
      [ Telemetry::Execution, attrs ]
    end

    def exception(rec)
      attrs = envelope(rec)
      attrs[:class_name] = rec["class"].to_s
      attrs[:message] = rec["message"].to_s
      attrs[:handled] = rec["handled"] ? true : false
      attrs[:severity] = rec["severity"]
      attrs[:source] = rec["source"]
      attrs[:file] = rec["file"]
      attrs[:line] = rec["line"]
      attrs[:frames] = rec["frames"] || []
      attrs[:cause] = rec["cause"]
      attrs[:locals] = rec["locals"].is_a?(Hash) ? rec["locals"] : nil
      attrs[:context] = rec["context"]
      attrs[:fingerprint] = rec["fingerprint"] || []
      attrs[:fingerprint_source] = rec["fingerprint_source"]
      attrs[:ruby_version] = rec["ruby_version"]
      attrs[:rails_version] = rec["rails_version"]
      [ Telemetry::Exception, attrs ]
    end

    def enqueued_job(rec)
      attrs = envelope(rec)
      attrs[:job_id] = rec["job_id"]
      attrs[:name] = rec["name"].to_s
      attrs[:queue] = rec["queue"]
      attrs[:adapter] = rec["adapter"]
      attrs[:priority] = rec["priority"]
      attrs[:scheduled_at] = rec["scheduled_at"] && timestamp_string(rec["scheduled_at"])
      attrs[:duration] = rec["duration"]
      attrs[:failed] = rec["failed"] ? true : false
      [ Telemetry::EnqueuedJob, attrs ]
    end

    # The gem ships collapsed stacks base64(gzip); stored as the gzip bytes.
    def profile(rec)
      attrs = envelope(rec)
      attrs[:profiler] = rec["profiler"]
      attrs[:mode] = rec["mode"]
      attrs[:interval] = rec["interval"]
      attrs[:duration] = rec["duration"]
      attrs[:samples] = rec["samples"]
      attrs[:stacks_bytes] = declared_bytes(rec["stacks_bytes"], "stacks_bytes",
        max_bytes: Telemetry::Profile::MAX_INGEST_BYTES)
      attrs[:stacks] = compressed_blob(rec["stacks"], "stacks")
      Telemetry::BoundedGzip.verify!(attrs[:stacks], max_bytes: Telemetry::Profile::MAX_INGEST_BYTES,
        expected_bytes: attrs[:stacks_bytes], utf8: true)
      [ Telemetry::Profile, attrs ]
    end

    def attachment(rec)
      attrs = envelope(rec)
      attrs[:name] = rec["name"]
      attrs[:content_type] = rec["content_type"]
      attrs[:bytes] = declared_bytes(rec["bytes"], "bytes", max_bytes: Telemetry::Attachment::MAX_BODY_BYTES)
      attrs[:data] = compressed_blob(rec["data"], "data")
      Telemetry::BoundedGzip.verify!(attrs[:data], max_bytes: Telemetry::Attachment::MAX_BODY_BYTES,
        expected_bytes: attrs[:bytes])
      attrs[:exception_group_hash] = rec["exception_group_hash"]
      attrs[:truncated] = rec["truncated"] ? true : false
      [ Telemetry::Attachment, attrs ]
    end

    def compressed_blob(value, field)
      Base64.strict_decode64(value.to_s)
    rescue ArgumentError
      raise ArgumentError, "#{field} is not valid base64"
    end

    def declared_bytes(value, field, max_bytes:)
      bytes = if value.is_a?(Integer)
        value
      elsif value.is_a?(String)
        # Check the O(1) byte length before scanning or converting. Without
        # this guard an otherwise-valid request can spend seconds turning a
        # multi-megabyte decimal string into a huge Integer merely to reject it.
        max_digits = max_bytes.to_s.bytesize
        value.to_i if value.bytesize <= max_digits && value.match?(/\A\d+\z/)
      end
      return bytes if bytes&.between?(0, max_bytes)

      raise ArgumentError, "#{field} must be an integer between 0 and #{max_bytes}"
    end

    # `id` is the gem's session key; `session_id` here, since the row has its
    # own primary key.
    def session(rec)
      attrs = envelope(rec)
      attrs[:session_id] = rec["id"].to_s
      attrs[:source] = rec["source"]
      attrs[:status] = rec["status"]
      attrs[:started_at] = rec["started_at"] && timestamp_string(rec["started_at"])
      attrs[:duration] = rec["duration"]
      attrs[:requests] = rec["requests"]
      attrs[:visits] = rec["visits"]
      attrs[:error_count] = rec["errors"]
      attrs[:ended] = rec["ended"] ? true : false
      [ Telemetry::Session, attrs ]
    end

    def span(rec)
      attrs = envelope(rec)
      attrs[:name] = rec["name"]
      attrs[:duration] = rec["duration"]
      attrs[:payload] = rec["attributes"]
      attrs[:status] = rec["status"]
      [ Telemetry::Span, attrs ]
    end

    def health(rec)
      [ Telemetry::HealthSample, {
        sampled_at: timestamp_string(rec["timestamp"]), pid: rec["pid"], role: rec["role"], server: rec["server"], deploy: rec["deploy"],
        threads_max: rec["threads_max"], threads_busy: rec["threads_busy"], backlog: rec["backlog"],
        pool_size: rec["pool_size"], pool_busy: rec["pool_busy"], pool_waiting: rec["pool_waiting"],
        queue_depth: rec["queue_depth"], queue_latency: rec["queue_latency"], memory: rec["memory"],
        # The gem packs queues, workers, requests_count, running,
        # max_threads_reached, and recurring_tasks into one JSON string
        # under `detail` (lib/railwatch/health.rb). Slicing those names off
        # the top of the record found nothing, so every health sample landed
        # with an empty detail and the queue-depth panel stayed blank.
        detail: rec["detail"] || {}
      } ]
    end

    def process(rec)
      [ Telemetry::Process, {
        booted_at: timestamp_string(rec["timestamp"]), pid: rec["pid"], role: rec["role"], server: rec["server"],
        deploy: rec["deploy"], ruby_version: rec["ruby_version"], rails_version: rec["rails_version"],
        # Gems older than 0.1.3 send lantern_version; processes recorded
        # by one are still readable.
        railwatch_version: rec["railwatch_version"] || rec["lantern_version"], boot_seconds: rec["boot_seconds"],
        detail: rec.slice("app", "environment", "database_adapter", "queue_adapter", "cache_store")
      } ]
    end

    # Applies the casts AR would apply on save, but that raw SQL bypasses:
    # JSON-encode hashes/arrays, format times as UTC strings, booleans as
    # 0/1, coerce numeric columns, truncate strings to their column limit,
    # and substitute the column's default when a NOT NULL column (frames,
    # tags, only, ...) was left out of the wire record - the raw insert
    # skips SQLite's own DEFAULT clause because it names every column
    # explicitly, so a bare nil would otherwise hit a NOT NULL violation
    # that AR's insert would have silently defaulted around.
    def serialize(klass, attrs, truncations: nil)
      out = {}
      serialization_columns_for(klass).each do |name, type, limit, null, default|
        next unless attrs.key?(name)
        value = attrs[name]
        value = default if value.nil? && !null && !default.nil?
        out[name] = cast_value(value, type, limit, klass: klass, name: name, truncations: truncations)
      end
      return out if out.size == attrs.size

      # Mapper attribute sets are fixed and take the allocation-free path
      # above. Preserve serialize's behavior for callers with an unexpected
      # key, including the useful KeyError identifying a missing column.
      columns = columns_for(klass)
      attrs.each do |name, value|
        type, limit, null, default = columns.fetch(name.to_s)
        value = default if value.nil? && !null && !default.nil?
        out[name] = cast_value(value, type, limit, klass: klass, name: name, truncations: truncations)
      end
      out
    end

    # Wire timestamps are rounded to integer microseconds, then only one
    # Time per distinct second supplies the UTC calendar prefix. This avoids
    # the Rational/divmod work MRI repeats for every calendar field on a Time
    # constructed from a Float while preserving SQLite's six-digit format.
    def timestamp_string(value)
      microseconds = (Float(value) * 1_000_000).round
      seconds = microseconds / 1_000_000
      usec = microseconds - (seconds * 1_000_000)
      cache = Thread.current[TIME_PREFIX_CACHE_KEY] ||= {}
      prefix = cache[seconds]
      unless prefix
        cache.clear if cache.size >= TIME_PREFIX_CACHE_LIMIT
        time = Time.at(seconds).utc
        prefix = format("%04d-%02d-%02d %02d:%02d:%02d.", time.year, time.month, time.day, time.hour, time.min, time.sec).freeze
        cache[seconds] = prefix
      end
      prefix + format("%06d", usec)
    end

    # Kept for callers that pass Time values directly to cast_value; wire
    # timestamps already arrive here as their final SQLite string.
    def format_time(value)
      t = value.utc
      format("%04d-%02d-%02d %02d:%02d:%02d.%06d", t.year, t.month, t.day, t.hour, t.min, t.sec, t.usec)
    end

    def cast_value(value, type, limit, klass: nil, name: nil, truncations: nil)
      return nil if value.nil?
      if type == :json
        # Health detail is already JSON-encoded on the wire. Decode it before
        # sanitising so the database stores an object, not a JSON string that
        # merely contains another document.
        value = JSON.parse(sanitize_string(value)) if value.is_a?(String)
        sanitized = sanitize_json(value)
        encoded = JSON.generate(sanitized)
        replacement = sanitized.is_a?(Array) ? JSON_ARRAY_TRUNCATED : JSON_TRUNCATED
        return cap_text(encoded, text_limit(klass, name), klass, name, truncations, replacement: replacement)
      end
      if type == :datetime
        return value if value.is_a?(String)
        return format_time(value) if value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
      end
      if type == :boolean
        raise TypeError, "expected boolean" unless value == true || value == false

        return value ? 1 : 0
      end

      case value
      when Hash, Array
        raise TypeError, "unexpected #{value.class} for #{type.inspect} column"
      else
        case type
        when :string
          cap_text(sanitize_string(value.to_s), limit, klass, name, truncations)
        when :text
          cap_text(sanitize_string(value.to_s), text_limit(klass, name), klass, name, truncations)
        when :integer, :bigint
          # Signed: queue_latency and drift are clock differences between an
          # enqueuing host and a worker, and skew makes them negative.
          raise TypeError, "expected integer" unless value.is_a?(Integer)
          raise RangeError, "integer out of range" unless value.between?(INTEGER_MIN, INTEGER_MAX)
          value
        when :float
          raise TypeError, "expected number" unless value.is_a?(Numeric)
          number = value.to_f
          raise RangeError, "number out of range" unless number.finite?
          number
        else value
        end
      end
    end

    def text_limit(klass, name)
      return nil unless klass && name
      TEXT_LIMITS.fetch("#{klass.table_name}.#{name}")
    end
    private_class_method :text_limit

    def cap_text(value, limit, klass, name, truncations, replacement: nil)
      return value unless limit && value.bytesize > limit

      truncations << "#{klass.table_name}.#{name}" if truncations
      replacement || value.byteslice(0, limit).scrub("")
    end
    private_class_method :cap_text

    def sanitize_json(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, child), out|
          out[sanitize_string(key.to_s)] = sanitize_json(child)
        end
      when Array
        value.map { |child| sanitize_json(child) }
      when String
        sanitize_string(value)
      else
        value
      end
    end
    private_class_method :sanitize_json

    CONTROL_RANGE = "\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F"
    CONTROL_CHARS = /[#{CONTROL_RANGE}]/

    # scrub + delete allocate two strings per value, and this runs on every
    # string column of every record -- half the mapper's time on a real
    # batch, in which not one string needed cleaning. Check first; only
    # copy when there is something to remove.
    def sanitize_string(value)
      return value if value.valid_encoding? && !value.match?(CONTROL_CHARS)

      value.scrub.delete(CONTROL_RANGE)
    end
    private_class_method :sanitize_string
  end
end
