# frozen_string_literal: true

require "spec_helper"

RSpec.describe Railwatch::MonitoringHealth do
  include ActiveSupport::Testing::TimeHelpers

  let(:environment) { Railwatch::Environment.current }
  let(:now) { Time.utc(2026, 9, 22, 14, 20) }
  let(:config) { Railwatch::Configuration.new.tap { |c| c.transport = :local } }
  let(:reader) { described_class.new(environment, now: now, config: config) }

  def batch(**attributes)
    Railwatch::Telemetry::IngestBatch.create!({ received_at: now, accepted: 10 }.merge(attributes))
  end

  it "keeps never-recorded telemetry unknown and disabled export not applicable" do
    snapshot = reader.to_h

    expect(snapshot[:freshness][:ingest]).to include(status: "unknown", at: nil)
    expect(snapshot[:freshness][:health]).to include(status: "unknown", at: nil)
    expect(snapshot[:capture]).to include(status: "unknown", accepted: nil, rejected: nil, dropped_by_client: nil)
    expect(snapshot[:export]).to include(status: "not_applicable", enabled: false)
    expect(snapshot[:attention]).to be_empty
  end

  it "reports recorded loss and backpressure separately from stale batch and process timestamps" do
    batch(received_at: now - 11.minutes, rejected: 2, dropped_by_client: 3, backpressure_factor: 4)
    Railwatch::Telemetry::HealthSample.create!(sampled_at: now - 12.minutes)

    snapshot = reader.to_h

    expect(snapshot[:freshness][:ingest]).to include(status: "warning", age_seconds: 660)
    expect(snapshot[:freshness][:health]).to include(status: "warning", age_seconds: 720)
    expect(snapshot[:capture]).to include(status: "warning", accepted: 10, rejected: 2, dropped_by_client: 3, max_backpressure_factor: 4.0)
    expect(reader.summary[:attention].map { |item| item[:key] }).to include("freshness", "capture")
    expect(reader.summary.keys).to contain_exactly(:status, :checked_at, :attention)
  end

  it "bounds the inspected batches and labels partial totals rather than claiming to cover the whole hour" do
    Railwatch::Telemetry::IngestBatch.insert_all!((0..described_class::BATCH_LIMIT).map do |i|
      { received_at: now - i.seconds, accepted: 1, dropped_by_client: i == described_class::BATCH_LIMIT ? 90 : 0 }
    end)

    expect(reader.to_h[:capture]).to include(batches: 1_000, limited: true, accepted: 1_000, dropped_by_client: 0,
                                          covered_from: now - 999.seconds)
  end

  it "does not call a timestamp in the future fresh" do
    Railwatch::Telemetry::HealthSample.create!(sampled_at: now + 1.hour)

    expect(reader.to_h[:freshness][:health]).to include(status: "unknown", age_seconds: nil)
  end

  it "bounds pending follow-ups while retaining the oldest wait as a warning" do
    Railwatch::Telemetry::IngestBatch.insert_all!((0..204).map do |i|
      { received_at: now - 10.minutes + i.seconds, followups: { group_exception_ids: [ i ] } }
    end)

    expect(reader.to_h[:followups]).to include(status: "warning", pending: 200, limited: true,
                                            oldest_at: now - 10.minutes, age_seconds: 600)
  end

  it "distinguishes overdue, active, never-run and inapplicable maintenance without exposing lease owners" do
    Railwatch::MaintenanceTask.create!(name: "drain_followups", last_run_at: now - 30.minutes,
                                      lease_owner: "secret-lease-token", lease_expires_at: now - 1.minute)
    Railwatch::MaintenanceTask.create!(name: "prune", last_run_at: now - 2.days, lease_expires_at: now + 5.minutes)

    maintenance = reader.to_h[:maintenance]
    tasks = maintenance[:tasks].index_by { |task| task[:name] }

    expect(tasks["drain_followups"]).to include(status: "warning", state: "Overdue")
    expect(tasks["prune"]).to include(status: "ok", state: "Lease active")
    expect(tasks["release_health"]).to include(status: "unknown", state: "Never recorded")
    expect(tasks["export_expiry"]).to include(status: "not_applicable")
    expect(maintenance.to_json).not_to include("secret-lease-token", "lease_owner")
  end

  it "reports expired rows while respecting the partial hour retained for sessions" do
    allow(environment).to receive(:retention_days).and_return(7)
    cutoff = now - 7.days
    batch(received_at: cutoff - 2.days)
    Railwatch::Telemetry::Session.create!(occurred_at: cutoff - 10.minutes, session_id: "partial-hour")

    probes = reader.to_h[:retention][:probes].index_by { |probe| probe[:table] }

    expect(probes["ingest_batches"]).to include(status: "warning", expired: true)
    expect(probes["sessions"]).to include(status: "ok", expired: false)
  end

  it "keeps normally expired rows visible without warning before the next daily prune" do
    batch(received_at: now - 7.days - 12.hours)

    retention = reader.to_h[:retention]

    expect(retention[:status]).to eq("ok")
    expect(retention[:probes].find { |probe| probe[:table] == "ingest_batches" }).to include(expired: true, behind: false)
  end

  it "uses the configured retention period for both the environment and its backlog checks" do
    previous = Railwatch.config.retention_days
    Railwatch.config.retention_days = 14
    batch(received_at: now - 10.days)

    expect(environment.retention_days).to eq(14)
    expect(reader.to_h[:retention]).to include(days: 14, cutoff: now - 14.days, status: "ok")
  ensure
    Railwatch.config.retention_days = previous
  end

  it "prunes only beyond configured retention and leaves recent data when the advisory budget is exceeded" do
    previous_days = Railwatch.config.retention_days
    previous_budget = Railwatch.config.telemetry_storage_budget_bytes
    Railwatch.config.retention_days = 14
    Railwatch.config.telemetry_storage_budget_bytes = 1
    retained = batch(received_at: now - 10.days)
    expired = batch(received_at: now - 15.days)
    allow(Railwatch::TelemetryRecord.connection).to receive(:execute).and_wrap_original do |original, sql, *rest|
      original.call(sql, *rest) unless sql.to_s.start_with?("PRAGMA wal_checkpoint")
    end

    travel_to(now) { Railwatch::PruneTelemetryJob.new.perform(environment, checkpoint: "PASSIVE") }

    expect(Railwatch::Telemetry::IngestBatch.exists?(retained.id)).to be(true)
    expect(Railwatch::Telemetry::IngestBatch.exists?(expired.id)).to be(false)
  ensure
    Railwatch.config.retention_days = previous_days
    Railwatch.config.telemetry_storage_budget_bytes = previous_budget
  end

  it "skips a retention probe when its index is missing instead of scanning the table" do
    connection = Railwatch::TelemetryRecord.connection
    allow(connection).to receive(:indexes).and_call_original
    allow(connection).to receive(:indexes).with("logs").and_return([])
    statements = []
    capture = ->(*args) { statements << args.last[:sql] }

    snapshot = ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { reader.to_h }

    expect(snapshot[:retention][:probes].find { |probe| probe[:table] == "logs" }).to include(status: "unknown")
    expect(statements.grep(/FROM ["`]?logs["`]?\b/i)).to be_empty
  end

  it "keeps reads bounded and never runs counts, checkpoints, vacuum, writes or socket probes" do
    batch
    statements = []
    capture = ->(*args) { statements << args.last[:sql] }
    expect(Railwatch::Writer).not_to receive(:listening?)

    ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { reader.to_h }

    expect(statements.grep(/\bCOUNT\s*\(|\b(?:INSERT|UPDATE|DELETE|VACUUM)\b|wal_checkpoint/i)).to be_empty
    expect(statements.grep(/SELECT .*FROM ["`]?(?:ingest_batches|health_samples|queries|logs|sessions|exceptions|export_deliveries)["`]? /i)).to all(match(/LIMIT/i))
  end

  it "does not create missing telemetry storage or turn an adapter error into diagnostic output" do
    allow(environment).to receive(:telemetry_exists?).and_return(false)
    expect(Railwatch::TelemetryRecord).not_to receive(:with_tenant)
    expect(environment).not_to receive(:with_telemetry)

    expect(reader.to_h[:storage][:status]).to eq("unknown")
  end

  it "keeps a failed check unknown and hides database errors while other checks remain available" do
    scope = Railwatch::Telemetry::HealthSample.recent
    allow(Railwatch::Telemetry::HealthSample).to receive(:recent).and_return(scope)
    allow(scope).to receive(:pick).and_raise(ActiveRecord::StatementInvalid, "private-path-and-SQL")
    batch

    snapshot = reader.to_h

    expect(snapshot[:freshness][:status]).to eq("unknown")
    expect(snapshot[:capture]).to include(status: "ok", accepted: 10)
    expect(snapshot.to_json).not_to include("private-path-and-SQL")
  end

  it "reports a budget breach without deleting any telemetry and exposes no database path" do
    batch
    config.telemetry_storage_budget_bytes = 1

    snapshot = nil
    expect { snapshot = reader.to_h }.not_to change { Railwatch::Telemetry::IngestBatch.count }

    expect(snapshot[:storage][:budget]).to include(status: "critical", bytes: 1)
    expect(snapshot[:storage][:physical_bytes]).to be_positive
    expect(snapshot[:storage][:allocated_bytes]).to be >= snapshot[:storage][:freelist_bytes]
    expect(snapshot.to_json).not_to include(Railwatch::TelemetryRecord.connection_db_config.database)
  end

  it "reports only the configured export destination and omits URLs, digests and payloads" do
    config.export_enabled = true
    config.export_url = "https://receiver.test/private-ingest?credential=hidden"
    config.export_token = "private-export-token"
    destination = Railwatch::Telemetry::ExportDestination.bind!(url: config.export_url, token: config.export_token, now: now)
    destination.update!(state: "unauthorized", queued_bytes: 320, queued_deliveries: 1,
                        counters: { "acked" => 2, "shed" => 17 }, reason: "private-error-text")
    destination.export_deliveries.create!(delivery_id: SecureRandom.uuid, selection_key: "batch-one", body: "private-payload",
      body_sha256: "a" * 64, metadata_sha256: "b" * 64, body_bytes: 320, ndjson_bytes: 600, record_count: 3,
      enqueued_at: now - 10.minutes, expires_at: now + 1.hour, next_attempt_at: now)

    snapshot = reader.to_h

    expect(snapshot[:export]).to include(status: "critical", destination_state: "unauthorized", queued_bytes: 320,
                                        queued_deliveries: 1, oldest_at: now - 10.minutes)
    expect(snapshot[:export][:counters]).to include("acked" => 2, "shed" => 17)
    expect(snapshot.to_json).not_to include(config.export_url, config.export_token, "private-payload", "private-error-text",
                                          destination.credential_sha256, destination.producer_id)
  end

  it "reports non-SQLite storage as not applicable without issuing SQLite statements" do
    connection = double(adapter_name: "PostgreSQL")
    expect(connection).not_to receive(:select_value)

    expect(described_class::SqliteStorage.new(connection).to_h).to include(status: "not_applicable", adapter: "PostgreSQL")
  end
end
