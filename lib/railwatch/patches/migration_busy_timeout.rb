# frozen_string_literal: true

module Railwatch
  module Patches
    # Gives the migration connection to a Railwatch database a long SQLite
    # busy timeout, for the migration only.
    #
    # A deploy migrates while the previous release is still serving, and on
    # an embedded install that release's writer process is committing
    # telemetry to the same file the whole time. Each of its transactions
    # takes SQLite's single write lock: about a second on a warm 15 GB file
    # (the export sender's claim scans the destination's whole delivery
    # history), several seconds while a deploy's image build has the disk.
    # The migration connection waited only the database's configured
    # `timeout` -- 5 s in the generated database.yml -- and then raised
    # SQLite3::BusyException, which db:prepare reports as a failed migration
    # and the container entrypoint as a failed boot. That is how a deploy of
    # rebulk-system crash-looped eight times without one migration running.
    #
    # The configured timeout is the right one for the app's own requests,
    # which should fail fast rather than queue behind ingest. A migration is
    # the opposite: it runs once, before the server binds, and waiting is the
    # only way through. So only the connection Active Record migrates with is
    # changed, only while it migrates, and only for a database whose
    # migrations_paths include this gem's. The host's own databases keep
    # their timeouts.
    module MigrationBusyTimeout
      def migrate(*, **)
        pool = migration_connection_pool
        raw = Railwatch::Patches::MigrationBusyTimeout.lengthen(pool)
        super
      ensure
        Railwatch::Patches::MigrationBusyTimeout.restore(pool, raw) if raw
      end

      class << self
        # The raw SQLite connection whose timeout was lengthened, or nil when
        # this is not a Railwatch database (or not SQLite).
        def lengthen(pool)
          return unless railwatch_database?(pool.db_config)

          raw = pool.lease_connection.raw_connection
          return unless raw.respond_to?(:busy_handler_timeout=)

          raw.busy_handler_timeout = (Railwatch.config.migration_busy_timeout.to_f * 1000).to_i
          raw
        rescue StandardError => e
          Railwatch.debug { "migration busy timeout not applied: #{e.class}: #{e.message}" }
          nil
        end

        # Back to what database.yml says, so a connection that outlives the
        # migration (db:migrate in a long-lived process, a spec) behaves as
        # configured afterwards.
        def restore(pool, raw)
          timeout = pool.db_config.configuration_hash[:timeout]
          if timeout
            raw.busy_handler_timeout = Integer(timeout)
          else
            raw.busy_handler(nil)
          end
        rescue StandardError => e
          Railwatch.debug { "migration busy timeout not restored: #{e.class}: #{e.message}" }
        end

        def railwatch_database?(db_config)
          ours = %i[railwatch railwatch_telemetry].map { |name| File.expand_path(Railwatch.migrations_path(name)) }
          Array(db_config.migrations_paths).any? { |path| ours.include?(File.expand_path(path.to_s, Rails.root.to_s)) }
        end
      end
    end
  end
end
