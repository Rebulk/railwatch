# frozen_string_literal: true

# The Tenants page and MCP's list_tenants sum every tenant-tagged request
# and job in the window per tenant. Through (app_tenant, occurred_at)
# SQLite finds the rows but fetches each from the table for kind, status,
# outcome, duration and user_ref: 8.1 s over 30 days on rebulk-system
# (358,000 tagged requests), and 24 s once in production, which held the
# web process -- and every ingest request queued behind it -- the whole
# time. This index carries every column those aggregates read, only for
# tagged rows: 131 ms for the same query, 41 MB, 1.6 s to build on a copy
# of that 16 GB file. An untagged app gets an empty index.
class AddTenantSummaryIndex < ActiveRecord::Migration[8.1]
  def change
    add_index :executions, [ :kind, :app_tenant, :occurred_at, :status, :outcome, :duration, :user_ref ],
              name: "idx_executions_tenant_summary", where: "app_tenant IS NOT NULL"
  end
end
