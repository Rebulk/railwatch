# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

# A deploy migrates the telemetry database while the previous release's
# writer is still committing to it. Each of that writer's transactions holds
# SQLite's only write lock; on a large file under a deploy's disk load that is
# several seconds. These examples hold the lock from a second process for
# longer than the database's configured timeout and migrate through the same
# DatabaseTasks.migrate call db:prepare and db:migrate make.
RSpec.describe Railwatch::Patches::MigrationBusyTimeout do
  self.use_transactional_tests = false

  CONFIGURED_TIMEOUT_MS = 500
  HOLD_SECONDS = 2

  around do |example|
    Railwatch::Patches.install_migration_busy_timeout!
    previous = Railwatch.config.migration_busy_timeout
    example.run
  ensure
    Railwatch.config.migration_busy_timeout = previous
  end

  def config_for(path, migrations_paths)
    ActiveRecord::DatabaseConfigurations::HashConfig.new(
      "test", "probe",
      { adapter: "sqlite3", database: path, timeout: CONFIGURED_TIMEOUT_MS, migrations_paths: migrations_paths }
    )
  end

  # A second process holding the write lock for HOLD_SECONDS, the way the
  # old release's writer does: BEGIN IMMEDIATE, a write, then the commit.
  # Yields once the lock is held.
  def with_writer_holding_lock(path)
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      db = SQLite3::Database.new(path)
      db.execute("PRAGMA journal_mode = wal")
      db.execute("BEGIN IMMEDIATE")
      db.execute("CREATE TABLE IF NOT EXISTS held (id integer)")
      writer.puts("held")
      writer.flush
      sleep HOLD_SECONDS
      db.execute("COMMIT")
      exit!(0)
    end
    writer.close
    # Bounded: a child that died before taking the lock must fail this
    # example, not hang the suite.
    held = reader.wait_readable(10) && reader.gets
    raise "lock holder never took the lock (#{Process.wait2(pid).last.inspect})" unless held == "held\n"

    yield
  ensure
    begin
      Process.wait(pid) if pid
    rescue Errno::ECHILD
      nil # already reaped by the diagnostic above
    end
  end

  def migrate(db_config)
    ActiveRecord::Tasks::DatabaseTasks.send(:with_temporary_pool, db_config) do
      quietly { ActiveRecord::Tasks::DatabaseTasks.migrate }
    end
  end

  # DatabaseTasks.migrate turns migration output on unless VERBOSE says not to.
  def quietly
    verbose = ENV["VERBOSE"]
    ENV["VERBOSE"] = "false"
    yield
  ensure
    ENV["VERBOSE"] = verbose
  end

  def versions(path)
    SQLite3::Database.new(path).execute("SELECT version FROM schema_migrations").flatten.map(&:to_i)
  end

  it "waits out a writer holding the telemetry database's lock past its configured timeout" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "telemetry.sqlite3")
      SQLite3::Database.new(path).execute("PRAGMA journal_mode = wal")
      Railwatch.config.migration_busy_timeout = HOLD_SECONDS * 5

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      with_writer_holding_lock(path) { migrate(config_for(path, Railwatch.migrations_path(:railwatch_telemetry))) }

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= HOLD_SECONDS - 0.5
      expect(versions(path)).to include(20260919000100, 20260925000000)
    end
  end

  # What the deploy hit, kept as the baseline: the same hold, with the
  # migration waiting only the configured timeout.
  it "still fails when told to wait no longer than the configured timeout" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "telemetry.sqlite3")
      SQLite3::Database.new(path).execute("PRAGMA journal_mode = wal")
      Railwatch.config.migration_busy_timeout = CONFIGURED_TIMEOUT_MS / 1000.0

      with_writer_holding_lock(path) do
        expect { migrate(config_for(path, Railwatch.migrations_path(:railwatch_telemetry))) }
          .to raise_error(StandardError, /database is locked/)
      end
    end
  end

  it "leaves a database whose migrations are not Railwatch's on its configured timeout" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "host.sqlite3")
      host_migrations = File.join(dir, "migrate")
      FileUtils.mkdir_p(host_migrations)
      File.write(File.join(host_migrations, "20260101000000_create_widgets.rb"), <<~RUBY)
        class CreateWidgets < ActiveRecord::Migration[8.1]
          def change = create_table(:widgets)
        end
      RUBY
      SQLite3::Database.new(path).execute("PRAGMA journal_mode = wal")
      Railwatch.config.migration_busy_timeout = HOLD_SECONDS * 5

      with_writer_holding_lock(path) do
        expect { migrate(config_for(path, host_migrations)) }.to raise_error(StandardError, /database is locked/)
      end
    end
  end

  it "puts the configured timeout back once the migration is done" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "telemetry.sqlite3")
      Railwatch.config.migration_busy_timeout = 30
      db_config = config_for(path, Railwatch.migrations_path(:railwatch_telemetry))

      ActiveRecord::Tasks::DatabaseTasks.send(:with_temporary_pool, db_config) do |pool|
        quietly { ActiveRecord::Tasks::DatabaseTasks.migrate }
        SQLite3::Database.new(path).execute("PRAGMA journal_mode = wal")

        with_writer_holding_lock(path) do
          started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          expect { pool.lease_connection.execute("INSERT INTO ingest_batches (received_at) VALUES ('2026-10-06')") }
            .to raise_error(ActiveRecord::StatementTimeout)
          expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < HOLD_SECONDS
        end
      end
    end
  end

  # The path a deploy takes, end to end: `db:prepare` through Rails' own rake
  # task in a fresh process with Railwatch disabled, the patch installed by
  # load_tasks rather than by this spec, and the database's timeout coming
  # from database.yml.
  it "lets the entrypoint's db:prepare through a held lock" do
    Dir.mktmpdir("railwatch-db-prepare") do |root|
      FileUtils.mkdir_p("#{root}/config")
      FileUtils.mkdir_p("#{root}/db")
      telemetry = "#{root}/telemetry.sqlite3"
      File.write("#{root}/config/database.yml", <<~YAML)
        test:
          primary:
            adapter: sqlite3
            database: #{root}/primary.sqlite3
          railwatch_telemetry:
            adapter: sqlite3
            database: #{telemetry}
            timeout: #{CONFIGURED_TIMEOUT_MS}
            migrations_paths: #{Railwatch.migrations_path(:railwatch_telemetry)}
            schema_dump: false
      YAML
      SQLite3::Database.new(telemetry).execute("PRAGMA journal_mode = wal")

      output, status = with_writer_holding_lock(telemetry) do
        Open3.capture2e(
          { "RAILS_ENV" => "test", "DB_PREPARE_BOOT_ROOT" => root, "RAILWATCH_ENABLED" => "0",
            "RAILWATCH_MIGRATION_BUSY_TIMEOUT" => (HOLD_SECONDS * 5).to_s },
          Gem.ruby, File.expand_path("../../fixtures/db_prepare_boot.rb", __dir__)
        )
      end

      expect(status.success?).to be(true), output
      expect(output).to include("DB_PREPARE_OK")
      expect(versions(telemetry)).to include(20260919000100, 20260925000000)
    end
  end
end
