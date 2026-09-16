# frozen_string_literal: true

# Base class for everything the engine stores about the host application.
# The hosted platform keeps one SQLite file per monitored environment through
# activerecord-tenanted; an embedded install monitors exactly one application,
# so this is a plain second database (`railwatch_telemetry` in the host's
# database.yml), separate from the host's own primary and from the engine's
# meta tables. Every telemetry query still runs inside
# Environment#with_telemetry so the code path matches the platform's.
class TelemetryRecord < ActiveRecord::Base
  self.abstract_class = true
  connects_to database: { writing: :railwatch_telemetry, reading: :railwatch_telemetry }

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
