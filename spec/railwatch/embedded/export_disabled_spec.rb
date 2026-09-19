# frozen_string_literal: true

require "spec_helper"

# An embedded install that has not asked to mirror anything must pay nothing
# for the fact that mirroring exists.
RSpec.describe "export, switched off" do
  around do |example|
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = :http
  end

  let(:environment) { Railwatch::Environment.current }

  def request_record
    { "v" => 1, "t" => "request", "timestamp" => Time.now.to_f, "method" => "GET", "route" => "/widgets",
      "controller" => "widgets", "action" => "index", "status_code" => 200, "duration" => 12_000,
      "stages" => { "action" => 10_000 }, "counters" => { "queries" => 1 },
      "execution_id" => SecureRandom.uuid, "_group" => Digest::MD5.hexdigest("req") }
  end

  def ingest = Railwatch::Ingest::Batch.new(environment, [ request_record ], embedded: true,
                                            batch_id: SecureRandom.uuid).write!

  it "is off by default" do
    expect(Railwatch.config.export_enabled).to be(false)
    expect(Railwatch.config.export?).to be(false)
  end

  it "writes no row to either export table" do
    ingest

    environment.with_telemetry do
      expect(Railwatch::Telemetry::ExportDelivery.count).to eq(0)
      expect(Railwatch::Telemetry::ExportDestination.count).to eq(0)
    end
  end

  it "leaves the batch's own export columns empty, rather than recording a decision" do
    ingest

    ledger = environment.with_telemetry { Railwatch::Telemetry::IngestBatch.order(:id).last }
    expect(ledger.export_disposition).to be_nil
    expect(ledger.export_record_count).to be_nil
  end

  it "never encodes the batch a second time" do
    expect(Railwatch::Transport::WireEncoder).not_to receive(:new)
    ingest
  end

  it "refuses to half-enable when the configuration is unusable, and says why" do
    config = Railwatch.config
    allowed = config.allow_http
    config.export_enabled = true
    config.export_url = "http://plaintext.test/ingest"
    config.export_token = "rw"
    config.allow_http = false

    expect(config.export?).to be(false)
    expect(config.export_problem).to include("HTTPS")
    ingest
    environment.with_telemetry { expect(Railwatch::Telemetry::ExportDelivery.count).to eq(0) }
  ensure
    config.export_enabled = false
    config.export_url = nil
    config.export_token = nil
    config.allow_http = allowed
  end

  it "refuses an http-transport install, which is already sending everything" do
    config = Railwatch.config
    config.transport = :http
    config.export_enabled = true

    expect(config.export?).to be(false)
    expect(config.export_problem).to include("transport :local")
  ensure
    config.export_enabled = false
  end

  it "refuses a policy it does not implement rather than quietly sending everything" do
    config = Railwatch.config
    config.export_enabled = true
    config.export_policy = :minimal
    config.export_url = "https://receiver.test/ingest"
    config.export_token = "rw"

    expect(config.export?).to be(false)
    expect(config.export_problem).to include("minimal")
  ensure
    config.export_enabled = false
    config.export_policy = :everything
    config.export_url = nil
    config.export_token = nil
  end
end
