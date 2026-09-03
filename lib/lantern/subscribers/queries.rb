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

      @connection_info = {}.compare_by_identity
      @sources = {}

      module_function

      # adapter name and db config name never change for a connection object.
      def connection_info(conn)
        @connection_info[conn] ||= begin
          adapter = conn.adapter_name.to_s.downcase
          db = (conn.pool.db_config.name rescue nil)
          [ adapter, db ].freeze
        end
      rescue StandardError
        [ "", nil ].freeze
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
          adapter, db = p[:connection] ? connection_info(p[:connection]) : [ "", nil ]
          group = SqlNormalizer.group(sql, adapter: adapter, connection_name: db)
          exe&.track_query_group(group)
          duration = micros(event)
          slow = event.duration >= Lantern.config.slow_query_threshold_ms
          n = exe ? exe.query_groups[group] : 0

          Lantern.record(:query,
            group: group,
            timestamp: started_at(event),
            sql: sql.length > MAX_SQL ? sql[0, MAX_SQL] : sql,
            name: p[:name],
            duration: duration,
            connection: db,
            adapter: adapter,
            async: p[:async] ? true : false,
            row_count: p[:row_count],
            affected_rows: p[:affected_rows],
            in_transaction: p[:transaction] ? true : false,
            source: source_for(group, slow),
            allocations: event.allocations)

          if exe && n == Lantern.config.n_plus_one_threshold
            Lantern.record(:n_plus_one, group: group, sql: SqlNormalizer.normalize(p[:sql], adapter: adapter)[0, 2048],
                           count: n, source: Backtrace.caller_location(skip: 3))
          end
        end

        subscribe("transaction.active_record") do |event|
          exe = execution
          exe&.count(:transactions)
          next unless recording?
          p = event.payload
          Lantern.record(:transaction, group: nil, timestamp: started_at(event),
                         duration: micros(event), outcome: p[:outcome].to_s,
                         connection: (p[:connection]&.pool&.db_config&.name rescue nil))
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
