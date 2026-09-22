# frozen_string_literal: true

module Railwatch
  class MonitoringHealth
    # Only database metadata and file stat calls. No checkpoint, vacuum,
    # dbstat traversal, row counting, or calls against the host's primary DB.
    class SqliteStorage
      def initialize(connection, budget_bytes: nil)
        @connection, @budget_bytes = connection, budget_bytes
      end

      def to_h
        unless @connection.adapter_name.match?(/sqlite/i)
          return { status: "not_applicable", adapter: @connection.adapter_name,
                   message: "SQLite storage diagnostics do not apply to this adapter." }
        end

        page_size = @connection.select_value("PRAGMA page_size").to_i
        allocated = @connection.select_value("PRAGMA page_count").to_i * page_size
        free = @connection.select_value("PRAGMA freelist_count").to_i * page_size
        mode = TelemetryRecord::AUTO_VACUUM_MODES.fetch(@connection.select_value("PRAGMA auto_vacuum").to_i, :unknown).to_s
        journal = @connection.select_value("PRAGMA journal_mode").to_s
        path = @connection.select_all("PRAGMA database_list").find { |row| row["name"] == "main" }&.fetch("file", nil)
        memory = path.blank? || path == ":memory:"
        data = memory ? nil : file_size(path)
        wal = memory ? nil : file_size("#{path}-wal", missing: 0)
        used = data && wal && data + wal
        budget = budget_for(used)
        status = if %w[critical warning unknown].include?(budget[:status]) then budget[:status]
        elsif !memory && used.nil? then "unknown"
        else "ok"
        end
        { status: status,
          adapter: "SQLite", allocated_bytes: allocated, active_bytes: allocated - free, freelist_bytes: free,
          data_bytes: data, wal_bytes: wal, physical_bytes: used, auto_vacuum: mode, journal_mode: journal,
          budget: budget, in_memory: memory,
          message: memory ? "In-memory SQLite has no data or WAL file to measure." :
            "Data and WAL are file sizes; allocated pages include reusable free pages. A large WAL can reflect delayed checkpoints or active readers. These readings do not modify storage." }
      end

      private

      def file_size(path, missing: nil)
        File.size(path)
      rescue Errno::ENOENT
        missing
      rescue SystemCallError, IOError
        nil
      end

      def budget_for(used)
        unless @budget_bytes.to_i.positive?
          return { status: "not_applicable", bytes: nil, used_bytes: used, percent: nil,
                   message: "No storage budget is configured. Retention controls age; it is not a disk-size ceiling." }
        end
        unless used
          return { status: "unknown", bytes: @budget_bytes, used_bytes: nil, percent: nil,
                   message: "A storage budget is configured, but the data and WAL file sizes could not be measured." }
        end
        percent = (used.to_f / @budget_bytes * 100).round(1)
        status = if used >= @budget_bytes then "critical"
        elsif used >= @budget_bytes * 0.8 then "warning"
        else "ok"
        end
        { status: status, bytes: @budget_bytes, used_bytes: used, percent: percent,
          message: "Data and WAL use #{percent}% of the configured budget. This is an advisory limit: it never deletes recent data or stops ingest." }
      end
    end
  end
end
