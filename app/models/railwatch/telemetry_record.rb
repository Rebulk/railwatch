# frozen_string_literal: true

module Railwatch
  # Base class for everything the engine stores about the host application.
  # The hosted platform keeps one SQLite file per monitored environment through
  # activerecord-tenanted; an embedded install monitors exactly one application,
  # so this is a plain second database (`railwatch_telemetry` in the host's
  # database.yml), separate from the host's own primary and from the engine's
  # meta tables. Every telemetry query still runs inside
  # Environment#with_telemetry so the code path matches the platform's.
  class TelemetryRecord < ActiveRecord::Base
    self.abstract_class = true
    begin
      connects_to database: { writing: :railwatch_telemetry, reading: :railwatch_telemetry }
    rescue ActiveRecord::AdapterNotSpecified, LoadError
      # No `railwatch_telemetry` entry in this environment's database.yml, or an entry
      # whose adapter gem is not in the bundle yet (LoadError). A cloud-transport
      # app has none and still eager-loads this class in production, and so
      # does the --local installer's own boot, before it has written the
      # entry -- so loading must not raise. Using it must, though: without
      # connects_to this class would inherit ActiveRecord::Base's PRIMARY
      # connection, and its tables are unprefixed, so a query would read and
      # a write would corrupt the host application's own tables. Every route
      # into the connection goes through connection_pool, so refusing here
      # fails closed for reads and writes alike.
      def self.connection_pool
        raise Railwatch::DatabaseNotConfigured,
              "the `railwatch_telemetry` database (everything the app reports) is not configured for the " \
              "#{Rails.env} environment; run `bin/rails generate railwatch:install --local` " \
              "or add it to config/database.yml (docs/embedded.md)"
      end
    end

    # SQLite's auto_vacuum modes. Deleted pages only leave the file in
    # :incremental, and only when PRAGMA incremental_vacuum asks for them;
    # :none (the default, and what every database created before
    # EnableIncrementalVacuum is in) keeps them on the freelist forever.
    AUTO_VACUUM_MODES = { 0 => :none, 1 => :full, 2 => :incremental }.freeze

    # Everything below reads and writes THIS database, never the host's. The
    # pragmas are per-database and there is no Active Record wrapper for them,
    # so they go through this class's own connection on purpose: through
    # ActiveRecord::Base they would report on, and vacuum, the application's
    # primary database instead.
    def self.sqlite? = connection.adapter_name.match?(/sqlite/i)

    def self.auto_vacuum_mode = sqlite? ? AUTO_VACUUM_MODES.fetch(connection.select_value("PRAGMA auto_vacuum").to_i, :unknown) : nil

    def self.freelist_pages = sqlite? ? connection.select_value("PRAGMA freelist_count").to_i : 0

    def self.page_size = sqlite? ? connection.select_value("PRAGMA page_size").to_i : 0

    # Hands freelist pages back to the filesystem, a slice at a time. Each
    # PRAGMA is its own implicit transaction, so the write lock is taken and
    # released once per slice rather than held for the whole reclaim -- the
    # same reason PruneTelemetryJob deletes in bounded batches instead of one
    # statement. Returns the pages actually reclaimed, which is 0 on a
    # database that is not in incremental mode: there the pragma is accepted
    # and does nothing, and calling it would look like work that happened.
    def self.reclaim_freelist!(slice:, slices:)
      return 0 unless sqlite? && auto_vacuum_mode == :incremental

      before = freelist_pages
      slices.times do
        break if freelist_pages.zero?

        incremental_vacuum(slice.to_i)
      end
      before - freelist_pages
    end

    # Through the raw connection on purpose. incremental_vacuum frees one page
    # per sqlite3_step, and Active Record's execute steps a statement with no
    # result columns exactly once -- so through it this pragma frees a single
    # page whatever count it is handed, which is the kind of no-op that reads
    # as work done. The sqlite3 gem's own execute steps to completion. Same
    # raw_connection route Ingest::Writer already takes for its inserts.
    def self.incremental_vacuum(pages = nil)
      connection.raw_connection.execute("PRAGMA incremental_vacuum#{"(#{pages})" if pages}")
    end

    # Records arrive as the gem's wire hashes; this is the shared envelope.
    def self.envelope_columns(t)
      t.datetime :occurred_at, null: false, precision: 6
      t.string :deploy, limit: 128
      t.string :server, limit: 255
      t.string :group_hash, limit: 32
      t.string :trace_id, limit: 36
      t.string :execution_source, limit: 20
      t.string :execution_id, limit: 36
      t.string :execution_preview, limit: 255
      t.string :execution_stage, limit: 32
      t.string :user_ref, limit: 255
      t.string :app_tenant, limit: 255
    end

    # Platform parity: callers wrap telemetry work in with_tenant. There is one
    # tenant here, so it is just the block.
    def self.with_tenant(_slug)
      yield
    end

    def self.tenant_exist?(_slug) = true
  end
end
