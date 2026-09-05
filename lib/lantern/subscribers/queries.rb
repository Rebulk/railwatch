# frozen_string_literal: true

module Lantern
  module Subscribers
    # sql.active_record, transactions, model hydration, strict loading.
    # Source location is only computed for slow queries or the first time a
    # group is seen in an execution, to keep the per-query cost tiny.
    module Queries
      extend Base

      SKIP_NAMES = %w[SCHEMA TRANSACTION EXPLAIN].freeze
      MAX_SQL = 16_384
      # Computed once so the hot query record doesn't look these up per call.
      QUERY_VERSION = Record::VERSIONS.fetch(:query)

      MAX_EXPLAIN = 4_000
      EXPLAIN_TTL = 600
      MAX_EXPLAINED_GROUPS = 1_000
      SELECT = /\A\s*select\b/i

      @connection_info = {}.compare_by_identity
      @sources = {}
      @explained = {}

      module_function

      # adapter name and db config name never change for a connection object.
      # Adapter, database name, and the multi-DB role the connection was
      # checked out for ("writing"/"reading"; Nightwatch calls this the
      # connection type). Memoised per connection object.
      def connection_info(conn)
        @connection_info[conn] ||= begin
          adapter = conn.adapter_name.to_s.downcase
          db = (conn.pool.db_config.name rescue nil)
          role = (conn.role.to_s rescue "writing")
          [ adapter, db, role ].freeze
        end
      rescue StandardError
        [ "", nil, "writing" ].freeze
      end

      # The app frame that issues a query shape rarely changes, so the
      # (expensive) caller walk runs once per group per process.
      def source_for(group, slow)
        return @sources[group] if @sources.key?(group) && !slow
        loc = Backtrace.caller_location(skip: 4)
        @sources.clear if @sources.size > 5_000
        @sources[group] = loc
        loc
      end

      # The query plan for a slow SELECT, off by default. Runs on the very
      # connection that just ran the query -- the adapter's own #explain, so
      # each database gets its native plan format -- with Lantern paused, and
      # with the EXPLAIN's own sql.active_record notification named "EXPLAIN"
      # and therefore already dropped by SKIP_NAMES above. Re-entering the
      # connection here is safe: the notification fires after the outer
      # statement's result has been materialized, and the adapter lock is
      # reentrant.
      def explain_for(payload, duration_ms, group)
        return nil unless duration_ms >= Lantern.config.explain_threshold_ms
        conn = payload[:connection] or return nil
        return nil unless SELECT.match?(payload[:sql])
        return nil unless explain_due?(group)

        plan = Lantern.ignore { conn.explain(payload[:sql], payload[:binds] || []) }
        plan&.to_s&.slice(0, MAX_EXPLAIN)
      rescue StandardError
        nil
      end

      # One EXPLAIN per query shape per process per EXPLAIN_TTL. Racy across
      # threads by design (worst case two threads explain the same shape
      # once), like @sources above.
      def explain_due?(group)
        now = Clock.monotonic
        last = @explained[group]
        return false if last && now - last < EXPLAIN_TTL
        @explained.clear if @explained.size >= MAX_EXPLAINED_GROUPS
        @explained[group] = now
        true
      end

      def install!(_app)
        subscribe("sql.active_record") do |event|
          p = event.payload
          next if SKIP_NAMES.include?(p[:name])
          exe = execution
          if p[:cached]
            exe&.count(:cached_queries)
            next
          end
          exe&.count(:queries)
          next unless recording?

          sql = p[:sql]
          adapter, db, role = p[:connection] ? connection_info(p[:connection]) : [ "", nil, "writing" ]
          # One cache lookup gets both the group hash and the normalized SQL,
          # so the (rare) n+1 branch below never re-normalizes the same text.
          group, normalized = SqlNormalizer.group_and_normalized(sql, adapter: adapter, connection_name: db)
          exe&.track_query_group(group)
          duration = micros(event)
          cfg = Lantern.config
          slow = event.duration >= cfg.slow_query_threshold_ms
          n = exe ? exe.query_groups[group] : 0

          # One hash literal (base keys + envelope + fields) instead of
          # kwargs-packing into Lantern.record and merging through
          # Record.build -- this is the hottest record type in the gem.
          Lantern.push(:query, {
            v: QUERY_VERSION,
            t: "query",
            timestamp: started_at(event),
            deploy: cfg.deploy,
            server: cfg.server,
            _group: group,
            **(exe ? exe.envelope : Record::EMPTY_ENVELOPE),
            sql: cfg.capture_sql_values ? SqlNormalizer.raw_for_record(sql, max_characters: MAX_SQL) : normalized[0, MAX_SQL],
            name: p[:name],
            duration: duration,
            connection: db,
            adapter: adapter,
            role: role,
            async: p[:async] ? true : false,
            row_count: p[:row_count],
            affected_rows: p[:affected_rows],
            in_transaction: p[:transaction] ? true : false,
            source: source_for(group, slow),
            allocations: event.allocations,
            # The EXPLAIN still runs on the raw statement -- the plan would be
            # meaningless otherwise -- and capture_query_explain keeps working
            # on its own. Only what is STORED changes: `sql` above is the
            # normalized shape. A plan can echo literal predicates (Postgres
            # does, in Filter/Index Cond lines), so capture_query_explain is
            # its own privacy decision, independent of capture_sql_values;
            # docs/configuration.md says so at both options.
            explain: cfg.capture_query_explain ? explain_for(p, event.duration, group) : nil
          })

          if exe && n == cfg.n_plus_one_threshold
            Lantern.record(:n_plus_one, group: group, sql: normalized[0, 2048],
                           count: n, source: Backtrace.caller_location(skip: 3))
          end
        end

        # Separate from the sql.active_record subscriber above (which stays a
        # tight hot path): counts statements against the currently-open
        # transaction, keyed by AR's transaction object identity. Payload
        # carries the same transaction object as the query subscriber sees
        # (current_transaction.user_transaction), so the two correlate.
        # Gated entirely behind "was there a transaction" — no per-query cost
        # outside that branch.
        subscribe("sql.active_record") do |event|
          p = event.payload
          next if SKIP_NAMES.include?(p[:name]) || p[:cached]
          txn = p[:transaction]
          execution&.count_transaction_statement(txn.object_id) if txn
        end

        subscribe("transaction.active_record") do |event|
          exe = execution
          exe&.count(:transactions)
          next unless recording?
          p = event.payload
          connection_name = (p[:connection]&.pool&.db_config&.name rescue nil)
          outcome = p[:outcome].to_s
          statement_count = p[:transaction] ? exe&.transaction_statement_count(p[:transaction].object_id) : nil
          Lantern.record(:transaction, group: Record.group_hash(connection_name, outcome),
                         timestamp: started_at(event), duration: micros(event), outcome: outcome,
                         connection: connection_name, statement_count: statement_count)
        end

        subscribe("instantiation.active_record") do |event|
          execution&.count(:hydrated_models, event.payload[:record_count].to_i)
        end

        subscribe("strict_loading_violation.active_record") do |event|
          exe = execution or next
          exe.count(:lazy_loads)
          next unless recording?
          p = event.payload
          Lantern.record(:log, level: "warn", message: "Lazy load of #{p[:owner].class.name}##{p[:reflection]&.name}",
                         tags: [ "strict_loading" ], context: "{}", source: Backtrace.caller_location(skip: 3))
        end
      end
    end
  end
end
