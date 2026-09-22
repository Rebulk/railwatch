# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

RSpec.describe Railwatch::RuntimeSchema, type: :request do
  around do |example|
    Railwatch.config.transport = :local
    described_class.invalidate!
    example.run
  ensure
    described_class.invalidate!
    Railwatch.config.transport = :http
  end

  def connection(name = "railwatch_telemetry")
    (name == "railwatch" ? Railwatch::ApplicationRecord : Railwatch::TelemetryRecord).connection
  end

  def latest_version(name)
    Dir[File.join(Railwatch.migrations_path(name), "[0-9]*_*.rb")].map { |file| File.basename(file).split("_", 2).first }.max
  end

  def remove_version(name)
    version = latest_version(name)
    connection(name).execute("DELETE FROM schema_migrations WHERE version = #{connection(name).quote(version)}")
    version
  end

  def restore_version(name, version)
    connection(name).execute("INSERT INTO schema_migrations (version) VALUES (#{connection(name).quote(version)})")
  end

  def database_status(name = "railwatch_telemetry", **options)
    described_class.status(**options).databases.find { |database| database.name == name }
  end

  it "keeps the table and column contract aligned with the shipped migrations" do
    described_class::CONTRACT.each do |name, tables|
      actual = connection(name).tables.reject do |table|
        table.start_with?("sqlite_", "logs_fts_") || %w[schema_migrations ar_internal_metadata].include?(table)
      end
      expect(tables.keys).to match_array(actual)
      tables.each do |table, columns|
        expect(columns).to match_array(connection(name).columns(table).map(&:name))
      end
    end
  end

  it "uses separate schema ledgers and gives exact commands for both databases" do
    engine_version = remove_version("railwatch")
    telemetry_version = remove_version("railwatch_telemetry")
    status = described_class.status

    expect(status.state).to eq(:pending)
    expect(database_status("railwatch").pending_versions).to eq([ engine_version ])
    expect(database_status.pending_versions).to eq([ telemetry_version ])
    expect(status.migration_commands).to eq([
      "RAILS_ENV=test bin/rails db:migrate:railwatch",
      "RAILS_ENV=test bin/rails db:migrate:railwatch_telemetry"
    ])
  end

  it "pauses capture, local ingest, writer ingest and maintenance while leaving host responses intact" do
    remove_version("railwatch_telemetry")
    expect(Railwatch::Ingest::Batch).not_to receive(:new)
    expect(Railwatch::MaintenanceTask).not_to receive(:claim)

    get "/widgets"
    expect(response).to have_http_status(:ok)
    Railwatch.report(RuntimeError.new("while schema is pending"))
    Railwatch.start_execution(source: :command)
    Railwatch.record(:log, message: "while schema is pending")
    Railwatch.finish_execution(:command, name: "schema test")
    expect(railwatch_records).to be_empty

    local = Railwatch::Transport::Local.new(Railwatch.config).deliver([], batch_id: SecureRandom.uuid)
    writer = Railwatch::Writer.write_batch("records" => [], "batch_id" => SecureRandom.uuid)
    [ local, writer ].each do |result|
      expect(result.ok).to be(false)
      expect(result.status).to eq(503)
      expect(result.retryable?).to be(true)
    end
    expect(Railwatch::Maintenance.tick).to eq([])
  end

  it "lets the Rails development migration check pass pending Railwatch schemas" do
    remove_version("railwatch")
    remove_version("railwatch_telemetry")
    expect { ActiveRecord::Migration.check_all_pending! }.not_to raise_error
    expect { ActiveRecord::Migration.check_pending_migrations }.not_to raise_error
  end

  it "keeps the Rails development check for pending host migrations" do
    context = ActiveRecord::Base.connection_pool.migration_context
    allow(ActiveRecord::Base.connection_pool).to receive(:migration_context).and_return(context)
    allow(context).to receive(:get_all_versions).and_return([])
    # A real Rails migration proxy, without creating a host migration file.
    migration = ActiveRecord::MigrationProxy.new("CreateHostWidgets", 20_260_922_000_001, "host/db/migrate/create_host_widgets.rb", nil)
    allow(context).to receive(:migrations).and_return([ migration ])
    allow(ActiveRecord::Tasks::DatabaseTasks).to receive(:with_temporary_connection).and_yield(ActiveRecord::Base.connection)
    expect { ActiveRecord::Migration.check_all_pending! }.to raise_error(ActiveRecord::PendingMigrationError, /CreateHostWidgets|create_host_widgets/)
    expect { ActiveRecord::Migration.check_pending_migrations }.to raise_error(ActiveRecord::PendingMigrationError, /CreateHostWidgets|create_host_widgets/)
  end

  it "does not claim host migration paths placed under a Railwatch configuration name" do
    config = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: "railwatch")
    allow(config).to receive(:migrations_paths).and_return([ Railwatch.migrations_path(:railwatch), Rails.root.join("db/migrate").to_s ])
    expect(described_class.owns_migrations?(config)).to be(false)
  end

  it "requires authentication before showing schema details and does not evaluate dashboard data" do
    remove_version("railwatch_telemetry")
    Railwatch.config.http_basic_auth_enabled = true
    Railwatch.config.http_basic_auth_user = "operator"
    Railwatch.config.http_basic_auth_password = "schema-password"
    expect(Railwatch::Environment.current).not_to receive(:last_seen_at)

    get "/railwatch/apps/1/envs/1/requests"
    expect(response).to have_http_status(:unauthorized)
    expect(response.body).not_to include("db:migrate", "pending Railwatch migration")

    get "/railwatch/apps/1/envs/1/requests", headers: {
      "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials("operator", "schema-password")
    }
    expect(response).to have_http_status(:service_unavailable)
    expect(response.headers["Retry-After"]).to eq("30")
    expect(response.headers["Cache-Control"]).to eq("no-store")
    expect(response.body).to include("RAILS_ENV=test bin/rails db:migrate:railwatch_telemetry", latest_version("railwatch_telemetry"))
  ensure
    Railwatch.config.http_basic_auth_enabled = false
    Railwatch.config.http_basic_auth_user = nil
    Railwatch.config.http_basic_auth_password = nil
  end

  it "keeps the beacon and dashboard assets available while schemas are pending" do
    remove_version("railwatch")
    post "/railwatch/beacon", params: { visits: [ { component: "Schema", duration_ms: 1 } ] }, as: :json
    expect(response).to have_http_status(:no_content)
    expect(railwatch_records).to be_empty

    asset = Dir[Rails.root.join("../../public/railwatch/assets/*.js")].first
    expect(asset).to be_present
    get "/railwatch/assets/assets/#{File.basename(asset)}"
    expect(response).to have_http_status(:ok)
  end

  it "recovers automatically after migration without checking on each record" do
    now = Railwatch::Clock.monotonic
    allow(Railwatch::Clock).to receive(:monotonic) { now }
    version = remove_version("railwatch_telemetry")
    pending = described_class.status
    expect(pending.state).to eq(:pending)
    restore_version("railwatch_telemetry", version)
    expect(described_class.status).to equal(pending)

    now += described_class::INTERVAL + 1
    expect(described_class.status).to be_ready
    statements = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") { |event| statements << event.payload[:sql] }
    20.times { expect(described_class.ready?).to be(true) }
    expect(statements).to be_empty
    ActiveSupport::Notifications.unsubscribe(subscription)
    subscription = nil

    get "/widgets"
    expect(response).to have_http_status(:ok)
    records = railwatch_records
    expect(records.map { |record| record[:t] }).to include("request")
    expect(Railwatch::Transport::Local.new(Railwatch.config).deliver(records, batch_id: SecureRandom.uuid).ok).to be(true)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  it "suppresses an execution that starts unavailable through completion after recovery" do
    version = remove_version("railwatch_telemetry")
    execution = Railwatch.start_execution(source: :command)
    expect(execution.schema_paused).to be(true)
    expect(execution.paused_depth).to eq(0)
    restore_version("railwatch_telemetry", version)
    expect(described_class.status(force: true)).to be_ready

    # Neither user resume nor a later keep decision makes a partial execution
    # complete. Even the immediate exception path must remain suppressed.
    Railwatch.resume
    Railwatch.keep!
    Railwatch.record(:log, message: "after recovery")
    Railwatch.record_now(:exception, message: "after recovery")
    Railwatch.finish_execution(:command, name: "spanned recovery")
    expect(railwatch_records).to be_empty

    Railwatch.start_execution(source: :command)
    Railwatch.record(:log, message: "new execution")
    Railwatch.finish_execution(:command, name: "after recovery")
    expect(railwatch_records.map { |record| record[:t] }).to eq(%w[log command])
  ensure
    Railwatch::Current.clear
  end

  it "suppresses a buffered tree when capture observes an outage before recovery" do
    execution = Railwatch.start_execution(source: :command)
    Railwatch.record(:log, message: "before outage")
    expect(execution.records.size).to eq(1)
    version = remove_version("railwatch_telemetry")
    described_class.invalidate!
    Railwatch.record(:log, message: "during outage")
    expect(execution.schema_paused).to be(true)

    restore_version("railwatch_telemetry", version)
    expect(described_class.status(force: true)).to be_ready
    Railwatch.record(:log, message: "after outage")
    Railwatch.finish_execution(:command, name: "spanned outage")
    expect(railwatch_records).to be_empty
  ensure
    Railwatch::Current.clear
  end

  it "suppresses an execution spanning a schema outage observed outside that execution" do
    execution = Railwatch.start_execution(source: :command)
    Railwatch.record(:log, message: "before outage")
    # A standalone status check has no execution to flag. Its generation is
    # still observed at this execution's next record or completion.
    Railwatch::Current.execution = nil
    version = remove_version("railwatch_telemetry")
    expect(described_class.status(force: true).state).to eq(:pending)
    restore_version("railwatch_telemetry", version)
    expect(described_class.status(force: true)).to be_ready
    expect(execution.schema_paused).to be_nil
    Railwatch::Current.execution = execution

    Railwatch.finish_execution(:command, name: "spanned independently observed outage")
    expect(execution.schema_paused).to be(true)
    expect(railwatch_records).to be_empty
  ensure
    Railwatch::Current.clear
  end

  it "does not treat a healthy schema refresh as an execution outage" do
    execution = Railwatch.start_execution(source: :command)
    Railwatch.record(:log, message: "before refresh")
    expect(described_class.status(force: true)).to be_ready
    expect(execution.schema_paused).to be_nil
    Railwatch.record(:log, message: "after refresh")
    Railwatch.finish_execution(:command, name: "healthy refresh")
    expect(railwatch_records.map { |record| record[:t] }).to eq(%w[log log command])
  ensure
    Railwatch::Current.clear
  end

  it "detects missing tables and columns even when migration versions are current" do
    connection.execute("ALTER TABLE queries RENAME COLUMN role TO previous_role")
    connection.execute("ALTER TABLE llm_calls RENAME TO unavailable_llm_calls")
    status = database_status
    expect(status.state).to eq(:incompatible)
    expect(status.pending_versions).to be_empty
    expect(status.missing_tables).to include("llm_calls")
    expect(status.missing_columns).to include("queries" => [ "role" ])
  end

  it "rejects a schema without the unique index required for safe batch replay" do
    connection.remove_index(:ingest_batches, :batch_id)
    status = database_status
    expect(status.state).to eq(:incompatible)
    expect(status.missing_indexes).to eq("ingest_batches" => [ "batch_id" ])

    connection.add_index(:ingest_batches, :batch_id, unique: true)
    expect(described_class.status(force: true)).to be_ready
  end

  it "handles a schema change after a cached success and recovers model and mapper caches" do
    expect(described_class.status).to be_ready
    Railwatch::Ingest::Mapper.columns_for(Railwatch::Telemetry::Query)
    connection.execute("ALTER TABLE queries RENAME TO unavailable_queries")

    get "/railwatch/apps/1/envs/1/queries"
    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).to include("Missing tables: queries")

    connection.execute("ALTER TABLE unavailable_queries RENAME TO queries")
    expect(described_class.status(force: true)).to be_ready
    expect(Railwatch::Ingest::Mapper.columns_for(Railwatch::Telemetry::Query)).to have_key("role")
    get "/railwatch/apps/1/envs/1/queries", headers: {
      "X-Inertia" => "true", "X-Inertia-Version" => Railwatch::AssetsHelper.digest
    }
    expect(response).to have_http_status(:ok)
  end

  it "clears stale mapper columns when a missing column is restored" do
    connection.execute("ALTER TABLE queries RENAME COLUMN role TO previous_role")
    Railwatch::Telemetry::Query.reset_column_information
    Railwatch::Ingest::Mapper.reset_schema_cache!
    expect(Railwatch::Ingest::Mapper.columns_for(Railwatch::Telemetry::Query)).not_to have_key("role")
    expect(database_status.state).to eq(:incompatible)

    connection.execute("ALTER TABLE queries RENAME COLUMN previous_role TO role")
    expect(described_class.status(force: true)).to be_ready
    columns = Railwatch::Ingest::Mapper.columns_for(Railwatch::Telemetry::Query)
    expect(columns).to have_key("role")
    expect(columns).not_to have_key("previous_role")
  end

  it "reports unavailable separately from stale schema without exposing connection details" do
    allow(Railwatch::TelemetryRecord.connection_pool).to receive(:with_connection)
      .and_raise(ActiveRecord::ConnectionNotEstablished, "secret-path-and-password")
    status = database_status
    expect(status.state).to eq(:unavailable)
    expect(status.pending_versions).to be_empty
    expect(status.migration_command).to be_nil
    expect(status.message).to include("schema compatibility is unknown")
    expect(status.message).not_to include("secret-path-and-password")
    get "/widgets"
    expect(response).to have_http_status(:ok)
  end

  it "does not mistake an inaccessible database file for a missing schema" do
    config = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: "railwatch_telemetry")
    path = File.expand_path(config.database, Rails.root)
    allow(File).to receive(:stat).and_call_original
    allow(File).to receive(:stat).with(path).and_raise(Errno::EACCES)
    status = database_status
    expect(status.state).to eq(:unavailable)
    expect(status.pending_versions).to be_empty
    expect(status.migration_command).to be_nil
  end

  it "refuses missing configuration without consulting an inherited primary pool" do
    configs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, include_hidden: true)
    allow(ActiveRecord::Base.configurations).to receive(:configs_for).and_return(configs.reject { |config| config.name == "railwatch_telemetry" })
    expect(Railwatch::TelemetryRecord).not_to receive(:connection_pool)
    expect(database_status.state).to eq(:not_configured)
  end

  it "rejects a shared primary file and an unsupported adapter before connecting" do
    configs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, include_hidden: true)
    telemetry_config = configs.find { |config| config.name == "railwatch_telemetry" }
    primary_config = configs.find { |config| config.name == "primary" }
    allow(telemetry_config).to receive(:database).and_return(primary_config.database)
    expect(Railwatch::TelemetryRecord).not_to receive(:connection_pool)
    expect(database_status.state).to eq(:unsupported)

    allow(telemetry_config).to receive(:adapter).and_return("postgresql")
    expect(database_status(force: true).state).to eq(:unsupported)
  end

  it "does not create a missing SQLite file while checking its schema" do
    config = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: "railwatch_telemetry")
    path = Rails.root.join("storage", "schema-check-#{SecureRandom.hex}.sqlite3").to_s
    allow(config).to receive(:database).and_return(path)
    expect(Railwatch::TelemetryRecord).not_to receive(:connection_pool)
    status = database_status
    expect(status.state).to eq(:pending)
    expect(status.migration_command).to eq("RAILS_ENV=test bin/rails db:create:railwatch_telemetry db:migrate:railwatch_telemetry")
    expect(File.exist?(path)).to be(false)
  end

  it "performs no connection or schema check for an HTTP collector" do
    Railwatch.config.transport = :http
    expect(ActiveRecord::Base).not_to receive(:configurations)
    expect(Railwatch::TelemetryRecord).not_to receive(:connection_pool)
    expect(Railwatch::ApplicationRecord).not_to receive(:connection_pool)
    expect(described_class.status.state).to eq(:disabled)
    expect(described_class.ready?).to be(true)
  end

  it "boots with empty local databases and resumes capture after real migrations in the same process" do
    Dir.mktmpdir("railwatch-schema-boot") do |root|
      FileUtils.mkdir_p("#{root}/config/initializers")
      FileUtils.mkdir_p("#{root}/app/controllers")
      File.write("#{root}/app/controllers/application_controller.rb", "class ApplicationController < ActionController::Base; end\n")
      File.write("#{root}/config/database.yml", <<~YAML)
        production:
          primary:
            adapter: sqlite3
            database: ':memory:'
          railwatch:
            adapter: sqlite3
            database: #{root}/railwatch.sqlite3
            migrations_paths: <%= Railwatch.migrations_path(:railwatch) %>
          railwatch_telemetry:
            adapter: sqlite3
            database: #{root}/railwatch_telemetry.sqlite3
            migrations_paths: <%= Railwatch.migrations_path(:railwatch_telemetry) %>
      YAML
      File.write("#{root}/config/initializers/railwatch.rb", <<~RUBY)
        Railwatch.configure do |config|
          config.transport = :local
          config.http_basic_auth_user = "operator"
          config.http_basic_auth_password = "schema-password"
        end
      RUBY
      output, result = Open3.capture2e(
        { "RAILS_ENV" => "production", "RAILWATCH_SCHEMA_BOOT_ROOT" => root },
        Gem.ruby, File.expand_path("../../fixtures/local_schema_boot.rb", __dir__))
      expect(result.success?).to be(true), output
      expect(output).to include("RAILWATCH_SCHEMA_BOOT_AND_RECOVERY_OK")
    end
  end

  it "boots safely when local database configurations are missing" do
    Dir.mktmpdir("railwatch-unconfigured-boot") do |root|
      FileUtils.mkdir_p("#{root}/config/initializers")
      FileUtils.mkdir_p("#{root}/app/controllers")
      File.write("#{root}/app/controllers/application_controller.rb", "class ApplicationController < ActionController::Base; end\n")
      File.write("#{root}/config/database.yml", "production:\n  adapter: sqlite3\n  database: ':memory:'\n")
      File.write("#{root}/config/initializers/railwatch.rb", <<~RUBY)
        Railwatch.configure do |config|
          config.transport = :local
          config.http_basic_auth_user = "operator"
          config.http_basic_auth_password = "schema-password"
        end
      RUBY
      output, result = Open3.capture2e(
        { "RAILS_ENV" => "production", "RAILWATCH_SCHEMA_BOOT_ROOT" => root, "RAILWATCH_SCHEMA_BOOT_UNCONFIGURED" => "true" },
        Gem.ruby, File.expand_path("../../fixtures/local_schema_boot.rb", __dir__))
      expect(result.success?).to be(true), output
      expect(output).to include("RAILWATCH_SCHEMA_UNCONFIGURED_BOOT_OK")
    end
  end
end
