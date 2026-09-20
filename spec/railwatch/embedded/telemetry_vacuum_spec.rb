# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Deleting telemetry does not give a SQLite file's space back on its own: the
# pages go on the freelist and are reused, never returned. Two things together
# change that, and neither is worth anything without the other -- the database
# has to be in auto_vacuum=incremental, which can only be arranged while it is
# still empty, and something has to run PRAGMA incremental_vacuum once pruning
# has freed pages.
RSpec.describe "telemetry database disk reclaim" do
  # Every pragma here is one transactional fixtures cannot host: VACUUM and
  # the WAL checkpoint that commits incremental_vacuum's truncation both
  # refuse to run inside an open transaction, and Rails wraps even a pool
  # opened mid-example. These examples work on real files and clean up after
  # themselves instead.
  self.use_transactional_tests = false

  MODES = { 0 => :none, 1 => :full, 2 => :incremental }.freeze

  def mode(connection) = MODES.fetch(connection.select_value("PRAGMA auto_vacuum").to_i)

  describe "EnableIncrementalVacuum" do
    # A telemetry database built the way a host's db:prepare builds one, from
    # the gem's own migrations, in a directory of its own.
    def migrate(path)
      config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
        "test", "probe",
        { adapter: "sqlite3", database: path, migrations_paths: Railwatch.migrations_path(:railwatch_telemetry) }
      )
      ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) do |connection|
        yield connection if block_given?
        connection.pool.migration_context.migrate
        return [ mode(connection), connection.tables ]
      end
    end

    it "leaves a database it created in incremental auto-vacuum, so pruning can return its pages" do
      Dir.mktmpdir do |dir|
        mode, tables = migrate(File.join(dir, "fresh.sqlite3"))

        expect(mode).to eq(:incremental)
        # The whole schema, not a run that stopped early: the mode is only
        # useful on a database that holds telemetry.
        expect(tables).to include("executions", "queries", "logs")
      end
    end

    it "leaves an existing database's mode alone rather than VACUUMing it mid-deploy" do
      Dir.mktmpdir do |dir|
        mode, tables = migrate(File.join(dir, "existing.sqlite3")) do |connection|
          connection.create_table(:already_here) { |t| t.string :whatever }
        end

        expect(mode).to eq(:none)
        expect(tables).to include("executions", "already_here")
      end
    end
  end

  # The constraint that has bitten this codebase before: the telemetry
  # pragmas must go through TelemetryRecord's connection, never
  # ActiveRecord::Base's. Nothing the gem does may change how the host's own
  # databases are stored.
  it "does not change the mode of the host's primary or the engine's meta database" do
    expect(mode(Railwatch::TelemetryRecord.connection)).to eq(:incremental)
    expect(mode(ActiveRecord::Base.connection)).to eq(:none)
    expect(mode(Railwatch::ApplicationRecord.connection)).to eq(:none)
  end

  describe Railwatch::PruneTelemetryJob do
    ROWS = 5_000

    around do |example|
      Railwatch.config.transport = :local
      example.run
    ensure
      Railwatch.config.transport = :http
      environment.with_telemetry do
        Railwatch::Telemetry::Execution.delete_all
        restore_incremental
      end
    end

    let(:environment) { Railwatch::Environment.current }

    def path = Rails.root.join(Railwatch::TelemetryRecord.connection_db_config.database.to_s)

    # Enough expired rows that reclaiming them is visible in the file, written
    # straight through the connection: this is about pages, not mapping.
    def seed_expired_rows
      connection = Railwatch::TelemetryRecord.connection
      connection.transaction do
        ROWS.times do
          connection.execute(<<~SQL.squish)
            INSERT INTO executions (occurred_at, kind, name, duration, execution_preview)
            VALUES ('2020-01-01 00:00:00', 'request', 'GET /reclaim', 1, '#{"padding " * 40}')
          SQL
        end
      end
      connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    end

    def convert_to(target)
      connection = Railwatch::TelemetryRecord.connection
      connection.execute("PRAGMA auto_vacuum = #{target}")
      connection.execute("VACUUM")
      connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    end

    def restore_incremental
      convert_to("incremental") unless mode(Railwatch::TelemetryRecord.connection) == :incremental
    end

    it "returns the pages it freed to the filesystem" do
      before = environment.with_telemetry do
        seed_expired_rows
        [ File.size(path), Railwatch::TelemetryRecord.freelist_pages ]
      end
      expect(before.last).to eq(0)

      described_class.new.perform(environment)

      environment.with_telemetry do
        expect(Railwatch::Telemetry::Execution.count).to eq(0)
        expect(Railwatch::TelemetryRecord.freelist_pages).to eq(0)
        expect(File.size(path)).to be < before.first
      end
    end

    it "is a clean no-op on a database still in auto_vacuum=none, which every install predating the migration is" do
      before = environment.with_telemetry do
        convert_to("none")
        seed_expired_rows
        File.size(path)
      end

      expect { described_class.new.perform(environment) }.not_to raise_error

      environment.with_telemetry do
        expect(Railwatch::Telemetry::Execution.count).to eq(0)
        # Pruned, but not reclaimed: the pages are on the freelist and the
        # file is exactly as big as it was. That is the state railwatch:vacuum
        # exists to get an install out of.
        expect(Railwatch::TelemetryRecord.freelist_pages).to be > 0
        expect(File.size(path)).to eq(before)
        expect(Railwatch::TelemetryRecord.reclaim_freelist!(slice: 100, slices: 1)).to eq(0)
      end
    end

    it "asks for no more than its bound in one go, so a huge backlog drains over nights instead of stalling one" do
      allow(Railwatch::TelemetryRecord).to receive(:freelist_pages).and_return(1_000_000)
      allow(Railwatch::TelemetryRecord).to receive(:incremental_vacuum)

      described_class.new.perform(environment)

      expect(Railwatch::TelemetryRecord).to have_received(:incremental_vacuum)
        .with(described_class::VACUUM_PAGES_PER_SLICE).exactly(described_class::VACUUM_SLICES).times
    end
  end
end
