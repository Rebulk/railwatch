# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

# CreateExportQueue was 20260919000000 through 0.5.0 and is 20260919000100
# since 0.5.1. An install that ran it under the old number sees the new one as
# pending, and the host's db:prepare -- which a deploy runs before the app
# boots -- has to get through it. These examples build each starting point
# from real migration files on real SQLite files, the way db:prepare does.
RSpec.describe "CreateExportQueue across its renumbering" do
  self.use_transactional_tests = false

  OLD_VERSION = 20260919000000
  NEW_VERSION = 20260919000100
  EXPORT_INDEXES = %w[
    index_export_destinations_on_url_sha256
    index_export_destinations_on_producer_id
    index_export_deliveries_on_export_destination_id
    index_export_deliveries_on_destination_and_delivery
    index_export_deliveries_on_destination_and_selection
    index_export_deliveries_live
    index_export_deliveries_expiring
    index_export_deliveries_finished
  ].freeze

  def migrate(path, migrations_paths)
    config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
      "test", "probe", { adapter: "sqlite3", database: path, migrations_paths: migrations_paths }
    )
    ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) do |connection|
      connection.pool.migration_context.migrate
      yield connection
    end
  end

  # The gem's migration directory as 0.5.0 and older shipped it: the same
  # export queue migration, under its old number.
  def old_layout(dir)
    FileUtils.mkdir_p(old = File.join(dir, "old_migrate"))
    Dir[File.join(Railwatch.migrations_path(:railwatch_telemetry), "*.rb")].each do |file|
      name = File.basename(file).sub("#{NEW_VERSION}_", "#{OLD_VERSION}_")
      FileUtils.cp(file, File.join(old, name))
    end
    old
  end

  def versions(connection) = connection.select_values("SELECT version FROM schema_migrations").map(&:to_i)

  def expect_whole_export_queue(connection)
    expect(connection.tables).to include("export_destinations", "export_deliveries")
    indexes = %w[export_destinations export_deliveries].flat_map { |t| connection.indexes(t).map(&:name) }
    expect(indexes).to match_array(EXPORT_INDEXES)
    expect(connection.column_exists?(:ingest_batches, :export_disposition)).to be(true)
    expect(connection.column_exists?(:ingest_batches, :export_record_count)).to be(true)
    expect(connection.foreign_keys(:export_deliveries).map(&:to_table)).to eq([ "export_destinations" ])
  end

  it "builds the whole export queue on a fresh database" do
    Dir.mktmpdir do |dir|
      migrate(File.join(dir, "fresh.sqlite3"), Railwatch.migrations_path(:railwatch_telemetry)) do |connection|
        expect_whole_export_queue(connection)
        expect(versions(connection)).to include(NEW_VERSION)
        expect(versions(connection)).not_to include(OLD_VERSION)
      end
    end
  end

  it "upgrades a database that ran it under the old number, keeping the rows already queued" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "upgraded.sqlite3")
      migrate(path, old_layout(dir)) do |connection|
        expect(versions(connection)).to include(OLD_VERSION)
        expect(versions(connection)).not_to include(NEW_VERSION)
        connection.execute(<<~SQL.squish)
          INSERT INTO export_destinations (url, url_sha256, producer_id, credential_sha256, created_at, updated_at)
          VALUES ('https://r.test/ingest', '#{"a" * 64}', 'p-1', '#{"b" * 64}', '2026-09-19', '2026-09-19')
        SQL
      end

      # This is the run that raised "table export_destinations already exists".
      migrate(path, Railwatch.migrations_path(:railwatch_telemetry)) do |connection|
        expect(versions(connection)).to include(OLD_VERSION, NEW_VERSION)
        expect(connection.pool.migration_context.needs_migration?).to be(false)
        expect_whole_export_queue(connection)
        expect(connection.select_value("SELECT producer_id FROM export_destinations")).to eq("p-1")
      end
    end
  end

  describe "rolling back" do
    def roll_back(path)
      migrate(path, Railwatch.migrations_path(:railwatch_telemetry)) do |connection|
        connection.pool.migration_context.run(:down, NEW_VERSION)
        yield connection
      end
    end

    it "keeps the queue the old number built, and what it holds" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "upgraded.sqlite3")
        migrate(path, old_layout(dir)) do |connection|
          connection.execute(<<~SQL.squish)
            INSERT INTO export_destinations (url, url_sha256, producer_id, credential_sha256, created_at, updated_at)
            VALUES ('https://r.test/ingest', '#{"a" * 64}', 'p-1', '#{"b" * 64}', '2026-09-19', '2026-09-19')
          SQL
        end

        roll_back(path) do |connection|
          expect(versions(connection)).to include(OLD_VERSION)
          expect(versions(connection)).not_to include(NEW_VERSION)
          expect_whole_export_queue(connection)
          expect(connection.select_value("SELECT producer_id FROM export_destinations")).to eq("p-1")
        end
      end
    end

    it "removes the queue it built itself" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "fresh.sqlite3")
        roll_back(path) do |connection|
          expect(versions(connection)).not_to include(NEW_VERSION)
          expect(connection.tables).not_to include("export_destinations", "export_deliveries")
          expect(connection.column_exists?(:ingest_batches, :export_disposition)).to be(false)
          expect(connection.column_exists?(:ingest_batches, :export_record_count)).to be(false)
        end
      end
    end
  end

  it "leaves a database that already ran it under the new number alone" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "current.sqlite3")
      migrate(path, Railwatch.migrations_path(:railwatch_telemetry)) { |connection| expect_whole_export_queue(connection) }

      migrate(path, Railwatch.migrations_path(:railwatch_telemetry)) do |connection|
        expect(connection.pool.migration_context.needs_migration?).to be(false)
        expect(versions(connection).count(NEW_VERSION)).to eq(1)
        expect_whole_export_queue(connection)
      end
    end
  end
end
