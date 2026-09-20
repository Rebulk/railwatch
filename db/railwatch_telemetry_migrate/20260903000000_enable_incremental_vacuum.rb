# frozen_string_literal: true

# Puts the telemetry database into incremental auto-vacuum mode, which is what
# lets PruneTelemetryJob hand the pages it frees back to the filesystem
# instead of parking them on the freelist forever. Without it the file only
# ever grows: deleting a day of telemetry frees pages for SQLite to reuse and
# returns not one byte to the disk.
#
# Why a migration, and why this version number. SQLite only lets a database
# leave auto_vacuum=none for free while it still holds no pages; after that
# the only way in is a full VACUUM, which rewrites the entire file with the
# write lock held. Declaring the pragma in config/database.yml cannot do it
# either: Rails applies its own DEFAULT_PRAGMAS before any declared ones, and
# `journal_mode = wal` writes the file header, so by the time
# `auto_vacuum = incremental` runs the database is no longer new and the
# statement is a silent no-op (measured: the mode comes out `none`).
#
# A migration is the one hook that runs both on a new install's db:prepare and
# on an existing install's upgrade, and this one is numbered below
# CreateTelemetry so that on a new database it runs while the file holds
# nothing but schema_migrations and ar_internal_metadata -- a few kilobytes,
# where the VACUUM that commits the mode is instant. Rails runs a pending
# migration whatever its version, so an existing install gets it too; there it
# does nothing at all, because converting a file that may be tens of gigabytes
# is not a decision a deploy gets to make. That one is `bin/rails
# railwatch:vacuum`, run deliberately, which says what it will cost first.
class EnableIncrementalVacuum < ActiveRecord::Migration[8.1]
  # VACUUM cannot run inside a transaction.
  disable_ddl_transaction!

  # Rails' own bookkeeping, which is present before the first migration runs
  # and so does not make a database "existing".
  BOOKKEEPING = %w[schema_migrations ar_internal_metadata].freeze

  def up
    return say("not SQLite (#{connection.adapter_name}); auto_vacuum does not apply") unless sqlite?
    return say("auto_vacuum is already incremental") if mode == "incremental"

    populated = connection.tables - BOOKKEEPING
    if populated.any?
      return say("#{populated.size} tables already here: left in auto_vacuum=#{mode}. Run " \
                 "`bin/rails railwatch:vacuum` to convert this database when you can spare the lock.")
    end

    connection.execute("PRAGMA auto_vacuum = incremental")
    connection.execute("VACUUM")
    say("auto_vacuum = #{mode}")
  end

  # Irreversible in the useful sense: going back to `none` is another whole
  # VACUUM, and nothing about the schema depends on the mode. Rolling back
  # leaves it where it is rather than spending that on an undo nobody asked
  # for.
  def down
    say("auto_vacuum left as #{sqlite? ? mode : connection.adapter_name}; use `PRAGMA auto_vacuum = none; VACUUM;` to undo it by hand")
  end

  private
    def sqlite? = connection.adapter_name.match?(/sqlite/i)

    def mode = { 0 => "none", 1 => "full", 2 => "incremental" }[connection.select_value("PRAGMA auto_vacuum").to_i]
end
