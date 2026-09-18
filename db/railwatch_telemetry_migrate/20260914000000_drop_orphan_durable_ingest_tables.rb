# frozen_string_literal: true

# Telemetry half of the primary migration of the same name: #84's
# rollup_cursors and source_maps, and #60's release_health_finalizations,
# stayed behind in every tenant after their code was reverted or replaced.
class DropOrphanDurableIngestTables < ActiveRecord::Migration[8.1]
  ORPHAN_TABLES = %w[release_health_finalizations rollup_cursors source_maps].freeze
  ORPHAN_VERSIONS = %w[20260904000013 20260905000100 20260905000200 20260905000400].freeze

  def up
    ORPHAN_TABLES.each { |table| drop_table table, if_exists: true }
    execute "DELETE FROM schema_migrations WHERE version IN (#{ORPHAN_VERSIONS.map { |v| "'#{v}'" }.join(", ")})"
  end

  def down
    raise ActiveRecord::IrreversibleMigration, "the dropped tables belonged to reverted code; there is nothing to restore"
  end
end
