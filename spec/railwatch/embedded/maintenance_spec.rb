# frozen_string_literal: true

require "spec_helper"

# The embedded install's own clock. Rails.env.test? keeps the thread from
# starting, so these drive Maintenance.tick by hand and check the lease
# table and the work each task leaves behind.
RSpec.describe Railwatch::Maintenance do
  include ActiveSupport::Testing::TimeHelpers

  around do |example|
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = :http
  end

  let(:environment) { Railwatch::Environment.current }
  let(:now) { Time.utc(2026, 9, 16, 14, 20, 0) }

  # The prune task ends in PRAGMA wal_checkpoint, which cannot run inside the
  # transaction transactional fixtures hold open. Swallowed here; its mode is
  # covered by prune_checkpoint_spec.
  before do
    allow(Railwatch::TelemetryRecord.connection).to receive(:execute).and_wrap_original do |original, sql, *rest|
      original.call(sql, *rest) unless sql.to_s.start_with?("PRAGMA wal_checkpoint")
    end
  end

  def wire(type, **fields)
    {
      "v" => 1, "t" => type.to_s, "timestamp" => now.to_f, "deploy" => "d1", "server" => "web-1",
      "_group" => Digest::MD5.hexdigest(fields.delete(:group) || type.to_s), "trace_id" => SecureRandom.uuid,
      "execution_source" => "request", "execution_id" => SecureRandom.uuid, "execution_preview" => "WidgetsController#index",
      "execution_stage" => "action", "user" => nil, "tenant" => nil
    }.merge(fields.transform_keys(&:to_s))
  end

  def write!(records)
    result = travel_to(now) { Railwatch::Ingest::Batch.new(environment, records, embedded: true).write! }
    expect(result.rejected).to eq(0), result.rejections.inspect
    result
  end

  def task(name) = Railwatch::MaintenanceTask.find_by(name: name)

  describe Railwatch::MaintenanceTask do
    it "lets exactly one of two racing processes claim a task" do
      first = described_class.claim("prune", every: 1.day, lease: 1.hour, owner: "a:1", now: now)
      second = described_class.claim("prune", every: 1.day, lease: 1.hour, owner: "b:2", now: now)

      expect([ first, second ]).to eq([ true, false ])
      expect(task("prune").lease_owner).to eq("a:1")
    end

    it "does not hand a task out again until its interval has passed since the last run" do
      described_class.claim("prune", every: 1.day, lease: 1.hour, owner: "a:1", now: now)
      described_class.release("prune", ran_at: now)

      expect(described_class.claim("prune", every: 1.day, lease: 1.hour, owner: "a:1", now: now + 23.hours)).to be(false)
      expect(described_class.claim("prune", every: 1.day, lease: 1.hour, owner: "a:1", now: now + 25.hours)).to be(true)
    end

    it "lets another process take over a lease whose owner never released it" do
      described_class.claim("prune", every: 1.day, lease: 1.hour, owner: "dead:9", now: now)

      expect(described_class.claim("prune", every: 1.day, lease: 1.hour, owner: "b:2", now: now + 30.minutes)).to be(false)
      expect(described_class.claim("prune", every: 1.day, lease: 1.hour, owner: "b:2", now: now + 61.minutes)).to be(true)
      expect(task("prune").lease_owner).to eq("b:2")
    end
  end

  describe ".tick" do
    it "runs every task on the first tick, records when, and releases the leases" do
      ran = described_class.tick(now: now)

      expect(ran).to match_array(described_class::TASKS.keys)
      described_class::TASKS.each_key do |name|
        expect(task(name)).to have_attributes(last_run_at: now, lease_owner: nil, lease_expires_at: nil)
      end
    end

    it "runs only the tasks whose interval has elapsed on later ticks" do
      described_class.tick(now: now)

      expect(described_class.tick(now: now + 90.seconds)).to eq([ "release_health" ])
      expect(described_class.tick(now: now + 6.minutes)).to match_array(%w[release_health performance_scan anomaly_scan])
    end

    it "reports a failing task and still runs the ones after it" do
      allow(Railwatch::ReleaseHealthRollupJob).to receive(:new).and_raise(RuntimeError, "boom")
      subscriber = Class.new do
        attr_reader :contexts
        def initialize = @contexts = []
        def report(_error, handled:, severity:, context:, source: nil) = @contexts << context
      end.new
      Rails.error.subscribe(subscriber)

      ran = described_class.tick(now: now)

      expect(ran).to match_array(described_class::TASKS.keys - [ "release_health" ])
      expect(subscriber.contexts).to include(hash_including(railwatch_maintenance: "release_health"))
      expect(task("release_health")).to have_attributes(last_run_at: now, lease_owner: nil)
    ensure
      Rails.error.unsubscribe(subscriber) if subscriber
    end

    it "does not record any of its own work as telemetry" do
      write!([ wire(:session, id: "s1", source: "server", status: "ok", started_at: now.to_f - 30, duration: 30_000_000,
                    requests: 3, errors: 0, ended: false) ])

      expect { described_class.tick(now: now) }.not_to change { railwatch_records.size }
    end

    it "builds the release-health aggregate for the hour from sessions written by the local transport" do
      write!([ wire(:session, id: "s1", source: "server", status: "ok", started_at: now.to_f - 30, duration: 30_000_000,
                    requests: 3, errors: 0, ended: false),
               wire(:session, id: "s2", source: "browser", status: "crashed", started_at: now.to_f - 10, duration: 10_000_000,
                    requests: 1, errors: 1, ended: true) ])

      travel_to(now) { described_class.tick(now: now) }

      health = environment.with_telemetry { Railwatch::Telemetry::ReleaseHealth.find_by(deploy: "d1", bucket: now.beginning_of_hour) }
      expect(health).to have_attributes(sessions: 2, sessions_crashed: 1)
    end

    it "never enqueues anything on the host's job queue" do
      write!([ wire(:session, id: "s1", source: "server", status: "ok", started_at: now.to_f - 30, duration: 30_000_000,
                    requests: 3, errors: 0, ended: false) ])

      expect { described_class.tick(now: now) }.not_to have_enqueued_job
      expect(enqueued_jobs).to be_empty
    end
  end

  describe ".start!" do
    it "starts no thread in the test environment or when the transport is not local" do
      described_class.start!
      expect(described_class.instance_variable_get(:@thread)).to be_nil

      Railwatch.config.transport = :http
      described_class.start!
      expect(described_class.instance_variable_get(:@thread)).to be_nil
    end
  end
end
