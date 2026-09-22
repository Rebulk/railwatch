# frozen_string_literal: true

require "json"
require "shellwords"
require "time"

module Railwatch
  # A read-only compatibility check for the two embedded databases. Checking
  # their named configurations precedes resolving either model: a missing or
  # incorrect entry must never cause a connection to the host's primary.
  module RuntimeSchema
    INTERVAL = 30
    DATABASES = { "railwatch" => :ApplicationRecord, "railwatch_telemetry" => :TelemetryRecord }.freeze
    # Generated from the gem's migrations. The spec compares this contract to
    # migrated databases so a migration that changes it needs an update here.
    CONTRACT = JSON.parse(File.read(File.expand_path("runtime_schema.json", __dir__))).transform_values do |tables|
      tables.transform_values { |columns| columns.split.freeze }.freeze
    end.freeze
    # These constraints make replay, grouping, leases and upserts safe. A
    # restore that loses one must not continue writing duplicate state.
    UNIQUE_INDEXES = {
      "railwatch" => {
        "railwatch_issues" => [ %w[application_id number], %w[environment_id group_hash] ],
        "railwatch_deploys" => [ %w[environment_id deploy] ],
        "railwatch_thresholds" => [ %w[environment_id target_kind target metric] ],
        "railwatch_alerts" => [ %w[burst_key], %w[delivery_key] ],
        "railwatch_maintenance_tasks" => [ %w[name] ],
        "railwatch_followup_receipts" => [ %w[batch_id group_hash] ]
      },
      "railwatch_telemetry" => {
        "executions" => [ %w[execution_id] ], "people" => [ %w[ref] ],
        "rollups" => [ %w[record_type group_hash bucket] ], "release_health" => [ %w[deploy bucket] ],
        "query_shapes" => [ %w[group_hash] ], "ingest_batches" => [ %w[batch_id] ],
        "export_destinations" => [ %w[url_sha256], %w[producer_id] ],
        "export_deliveries" => [ %w[export_destination_id delivery_id], %w[export_destination_id selection_key] ]
      }
    }.freeze

    DatabaseStatus = Data.define(:name, :state, :pending_versions, :missing_tables, :missing_columns, :missing_indexes, :message, :migration_command) do
      def ready? = state == :ready
      def as_json(*) = to_h
    end

    Status = Data.define(:state, :databases, :checked_at) do
      def ready? = state == :ready || state == :disabled
      def migration_commands = databases.filter_map(&:migration_command)
      def message
        return "Railwatch local schema checks are disabled for the HTTP collector." if state == :disabled
        return "Railwatch databases are ready." if ready?

        "Railwatch local capture and persistence are paused. " + databases.reject(&:ready?).map(&:message).join(" ")
      end
      def as_json(*)
        { state: state, ready: ready?, checked_at: checked_at, message: message,
          databases: databases.map(&:as_json), migration_commands: migration_commands }
      end
    end

    DISABLED = Status.new(state: :disabled, databases: [].freeze, checked_at: nil).freeze

    # Rails' development pending-migration page would otherwise prevent the
    # host request from reaching its controller, including the authenticated
    # Railwatch repair page. Keep that check for every host migration; only
    # the two dedicated gem migration paths belong to the guard below.
    module HostMigrationCheck
      def check_all_pending!
        return super unless Railwatch.config.local?

        railwatch_check_host_migrations!
      end

      def check_pending_migrations
        return super unless Railwatch.config.local?

        railwatch_check_host_migrations!
      end

      private

      def railwatch_check_host_migrations!
        pending = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).flat_map do |config|
          next [] if Railwatch::RuntimeSchema.owns_migrations?(config)

          ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) do |connection|
            context = connection.pool.migration_context
            versions = context.get_all_versions
            context.migrations.reject { |migration| versions.include?(migration.version) }
          end
        end
        raise ActiveRecord::PendingMigrationError.new(pending_migrations: pending) if pending.any?
      end
    end

    @mutex = Mutex.new
    @verified = {}
    @pid = Process.pid
    @pause_generation = 0

    module_function

    def owns_migrations?(config)
      DATABASES.key?(config.name) && Array(config.migrations_paths).map { |path| File.expand_path(path, Rails.root) } ==
        [ File.expand_path(Railwatch.migrations_path(config.name)) ]
    end

    def ready?
      return false if Thread.current[:railwatch_schema_check]
      return true unless Railwatch.config.local?

      status.ready?
    end

    # Once an execution spans a detected outage its buffered tree is partial,
    # even if the schemas recover before it ends. Keep that decision separate
    # from user pause/resume and sampling. The generation also catches an
    # outage observed by a reporter or dashboard thread between its records.
    def execution_ready?(execution)
      return false if Thread.current[:railwatch_schema_check]

      if execution && Railwatch.config.local? && execution.schema_generation.nil?
        execution.schema_generation = @pause_generation
      end
      ready = ready?
      if execution && (!ready || (execution.schema_generation && execution.schema_generation != @pause_generation))
        execution.schema_paused = true
      end
      ready && !execution&.schema_paused
    end

    # local: true is for an explicitly requested embedded dashboard. An HTTP
    # collector never resolves Active Record constants or opens a database.
    def status(force: false, local: false)
      return DISABLED unless local || Railwatch.config.local?

      restart_after_fork! if @pid != Process.pid
      key = [ Rails.env.to_s, ActiveRecord::Base.configurations.object_id ]
      now = Clock.monotonic
      cached = @cached
      return cached[:status] if !force && cached && cached[:key] == key && now < cached[:expires_at]

      @mutex.synchronize do
        cached = @cached
        return cached[:status] if !force && cached && cached[:key] == key && now < cached[:expires_at]

        Thread.current[:railwatch_schema_check] = true
        databases = DATABASES.map { |name, model| check_database(name, model) }.freeze
        state = %i[unsupported not_configured unavailable incompatible pending].find do |candidate|
          databases.any? { |database| database.state == candidate }
        end || :ready
        result = Status.new(state: state, databases: databases, checked_at: Time.now.utc.iso8601).freeze
        @pause_generation += 1 unless result.ready?
        @cached = { key: key, expires_at: Clock.monotonic + INTERVAL, status: result }
        result
      ensure
        Thread.current[:railwatch_schema_check] = nil
      end
    rescue StandardError, LoadError => error
      # Connection failures say nothing about migration state. Do not expose
      # exception messages: adapters can put credentials and paths in them.
      unavailable = database_status("railwatch", :unavailable,
        message: "Railwatch database status could not be checked (#{error.class.name}). Restore database access and retry; schema compatibility is unknown.")
      @pause_generation += 1
      Status.new(state: :unavailable, databases: [ unavailable ].freeze, checked_at: Time.now.utc.iso8601).freeze
    end

    def invalidate!
      @mutex.synchronize do
        @cached = nil
        @verified = {}
      end
      nil
    end

    def restart_after_fork!
      @mutex = Mutex.new
      @cached = nil
      @verified = {}
      @pid = Process.pid
    end

    def check_database(name, model)
      configs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, include_hidden: true)
      config = configs.find { |candidate| candidate.name == name }
      unless config
        return database_status(name, :not_configured,
          message: "#{name} is not configured. Run `bin/rails generate railwatch:install --local` and configure its separate SQLite database.")
      end
      unless config.adapter == "sqlite3"
        return database_status(name, :unsupported,
          message: "#{name} must use adapter: sqlite3 in a separate database. The host application may use its own adapter.")
      end
      unless owns_migrations?(config)
        return database_status(name, :unsupported,
          message: "#{name} must set migrations_paths to Railwatch.migrations_path(:#{name}) in config/database.yml.")
      end
      if config.database.to_s.empty? || config.database.start_with?("file:")
        return database_status(name, :unsupported,
          message: "#{name} must use a SQLite filesystem path; SQLite URI filenames are not supported.")
      end

      path = database_path(config)
      collision = configs.find do |other|
        other.name != name && other.adapter == "sqlite3" && path && same_file?(path, database_path(other))
      end
      if collision
        return database_status(name, :unsupported,
          message: "#{name} shares a file with #{collision.name}. Give each Railwatch database its own file before running migrations.")
      end

      command = migration_command(name)
      unless database_file_exists?(path)
        return database_status(name, :pending, pending_versions: required_versions(name),
          message: "#{name} has not been created. Create and migrate this Railwatch database.",
          migration_command: migration_command(name, create: true))
      end

      base = Railwatch.const_get(model)
      pool = base.connection_pool
      unless pool.db_config.name == name && pool.db_config.configuration_hash == config.configuration_hash
        return database_status(name, :unsupported,
          message: "#{name} is connected to a different configuration. Reload the application after correcting config/database.yml.")
      end

      pool.with_connection do |connection|
        tables = connection.select_values("SELECT name FROM sqlite_master WHERE type = 'table'")
        versions = tables.include?("schema_migrations") ? connection.select_values("SELECT version FROM schema_migrations") : []
        pending = required_versions(name) - versions
        unless pending.empty?
          return database_status(name, :pending, pending_versions: pending,
            message: "#{name} has #{pending.size} pending Railwatch migration(s).", migration_command: command)
        end

        signature = [ pool.object_id, connection.select_value("PRAGMA schema_version"), versions.sort ]
        return database_status(name, :ready, message: "#{name} is ready.") if @verified[name] == signature

        missing_tables = CONTRACT.fetch(name).keys - tables
        missing_columns = {}
        (CONTRACT.fetch(name).keys & tables).each do |table|
          columns = connection.select_all("PRAGMA table_info(#{connection.quote(table)})").map { |column| column["name"] }
          missing = CONTRACT.fetch(name).fetch(table) - columns
          missing_columns[table] = missing.freeze unless missing.empty?
        end
        missing_indexes = UNIQUE_INDEXES.fetch(name).filter_map do |table, required|
          next if missing_tables.include?(table)

          actual = connection.indexes(table).select { |index| index.unique && !index.where }.map(&:columns)
          missing = required - actual
          [ table, missing.map { |columns| columns.join(", ") }.freeze ] if missing.any?
        end.to_h
        if missing_tables.any? || missing_columns.any? || missing_indexes.any?
          return database_status(name, :incompatible, missing_tables: missing_tables, missing_columns: missing_columns,
            missing_indexes: missing_indexes,
            message: "#{name} is missing required Railwatch tables, columns or unique indexes even though its migrations are recorded. Restore a compatible backup or repair this Railwatch schema; migrations alone may not repair it.",
            migration_command: command)
        end

        # A migration in another process leaves model and mapper column caches
        # stale. Clear them only after a changed schema passes the check.
        pool.schema_cache.clear!
        base.descendants.each(&:reset_column_information)
        if name == "railwatch_telemetry"
          Ingest::Mapper.reset_schema_cache!
          Telemetry::Log.reset_fts_cache!
        end
        @verified[name] = signature
        database_status(name, :ready, message: "#{name} is ready.")
      end
    rescue StandardError, LoadError => error
      database_status(name, :unavailable,
        message: "#{name} is unavailable (#{error.class.name}). Restore database access and retry; schema compatibility is unknown.")
    end
    private_class_method :check_database

    def database_status(name, state, pending_versions: [], missing_tables: [], missing_columns: {}, missing_indexes: {}, message:, migration_command: nil)
      DatabaseStatus.new(name: name, state: state, pending_versions: pending_versions.freeze,
        missing_tables: missing_tables.freeze, missing_columns: missing_columns.freeze, missing_indexes: missing_indexes.freeze,
        message: message.freeze, migration_command: migration_command&.freeze).freeze
    end
    private_class_method :database_status

    def required_versions(name)
      Dir[File.join(Railwatch.migrations_path(name), "[0-9]*_*.rb")].map { |path| File.basename(path).split("_", 2).first }.sort
    end
    private_class_method :required_versions

    def migration_command(name, create: false)
      tasks = create ? "db:create:#{name} db:migrate:#{name}" : "db:migrate:#{name}"
      "RAILS_ENV=#{Shellwords.escape(Rails.env.to_s)} bin/rails #{tasks}"
    end
    private_class_method :migration_command

    def database_path(config)
      return nil if config.database == ":memory:" || config.database.to_s.empty?

      File.expand_path(config.database, Rails.root)
    end
    private_class_method :database_path

    def database_file_exists?(path)
      File.stat(path) if path
      true
    rescue Errno::ENOENT
      false
    end
    private_class_method :database_file_exists?

    def same_file?(left, right)
      return false unless right
      return true if left == right

      File.exist?(left) && File.exist?(right) && File.identical?(left, right)
    end
    private_class_method :same_file?
  end
end
