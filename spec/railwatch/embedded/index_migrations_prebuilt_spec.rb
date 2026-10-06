# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# Each of these index migrations reads the whole of a table that, on a large
# telemetry file, can take minutes to scan -- longer than a deploy's health
# check waits for db:prepare. An operator can build the indexes ahead of the
# deploy, while the old release still serves; the migrations then have to
# accept the index that is already there instead of raising.
RSpec.describe "telemetry index migrations over indexes built ahead of time" do
  self.use_transactional_tests = false

  INDEX_VERSIONS = [ 20260922000000, 20260923000000, 20260925000000 ].freeze
  INDEX_NAMES = %w[
    idx_executions_queue_stats idx_health_samples_series index_broadcasts_on_occurred_at
    idx_executions_with_preview idx_executions_people idx_executions_tenant_summary
  ].freeze

  def with_database(path)
    config = ActiveRecord::DatabaseConfigurations::HashConfig.new(
      "test", "probe", { adapter: "sqlite3", database: path, migrations_paths: Railwatch.migrations_path(:railwatch_telemetry) }
    )
    ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) { |connection| yield connection }
  end

  def index_names(connection)
    connection.select_values("SELECT name FROM sqlite_master WHERE type = 'index' AND name IN (#{INDEX_NAMES.map { |n| "'#{n}'" }.join(", ")})")
  end

  it "migrates past the indexes when an operator already built them, and still removes them on rollback" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "telemetry.sqlite3")

      # The statements an operator runs by hand: exactly what the migrations
      # create, taken from a database they built.
      ddl = with_database(path) do |connection|
        connection.pool.migration_context.migrate
        connection.select_values("SELECT sql FROM sqlite_master WHERE type = 'index' AND name IN (#{INDEX_NAMES.map { |n| "'#{n}'" }.join(", ")})")
      end
      expect(ddl.size).to eq(INDEX_NAMES.size)

      with_database(path) do |connection|
        context = connection.pool.migration_context
        INDEX_VERSIONS.reverse_each { |version| context.run(:down, version) }
        expect(index_names(connection)).to be_empty

        # Built ahead of the deploy, then the deploy's db:prepare.
        ddl.each { |sql| connection.execute(sql) }
        context.migrate
        expect(context.needs_migration?).to be(false)
        expect(index_names(connection)).to match_array(INDEX_NAMES)

        INDEX_VERSIONS.reverse_each { |version| context.run(:down, version) }
        expect(index_names(connection)).to be_empty
      end
    end
  end
end
