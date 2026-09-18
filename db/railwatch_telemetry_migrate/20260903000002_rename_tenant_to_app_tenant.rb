# frozen_string_literal: true

# activerecord-tenanted defines `#tenant` on every tenanted model (the DB the
# row lives in), which shadowed the wire record's own tenant column. The
# monitored app's tenant is a different thing, so it gets its own name.
class RenameTenantToAppTenant < ActiveRecord::Migration[8.1]
  TABLES = %i[executions queries exceptions cache_events mails broadcasts notifications outgoing_requests
              storage_ops view_renders logs enqueued_jobs transactions n_plus_ones deprecations visits].freeze

  def change
    TABLES.each { |t| rename_column t, :tenant, :app_tenant }
    rename_column :people, :tenant, :app_tenant
  end
end
