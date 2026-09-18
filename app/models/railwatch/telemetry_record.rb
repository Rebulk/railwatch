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
