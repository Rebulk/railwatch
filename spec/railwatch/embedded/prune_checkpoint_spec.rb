# frozen_string_literal: true

require "spec_helper"

RSpec.describe Railwatch::PruneTelemetryJob, "WAL checkpoint mode" do
  around do |example|
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = :http
  end

  let(:environment) { Railwatch::Environment.current }

  # A checkpoint cannot run inside the transaction transactional fixtures
  # hold open ("database table is locked"), so the pragma is recorded and
  # swallowed; everything else the job executes runs for real.
  def pragmas_run
    pragmas = []
    allow(Railwatch::TelemetryRecord.connection).to receive(:execute).and_wrap_original do |original, sql, *rest|
      next pragmas << sql if sql.to_s.start_with?("PRAGMA wal_checkpoint")

      original.call(sql, *rest)
    end
    yield
    pragmas
  end

  it "truncates the WAL by default, for a dedicated worker" do
    expect(pragmas_run { described_class.new.perform(environment) }).to eq([ "PRAGMA wal_checkpoint(TRUNCATE)" ])
  end

  it "checkpoints passively when asked, so a prune inside a web process never blocks the app's readers" do
    expect(pragmas_run { described_class.new.perform(environment, checkpoint: "PASSIVE") }).to eq([ "PRAGMA wal_checkpoint(PASSIVE)" ])
  end
end
