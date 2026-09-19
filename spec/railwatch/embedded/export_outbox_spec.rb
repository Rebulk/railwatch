# frozen_string_literal: true

require "spec_helper"

RSpec.describe Railwatch::Export::Outbox do
  around do |example|
    with_export(&example)
  end

  def with_export(url: "https://receiver.test/ingest", token: "rw_token", **overrides)
    config = Railwatch.config
    previous = { enabled: config.export_enabled, url: config.export_url, token: config.export_token,
                 bytes: config.export_max_bytes, count: config.export_max_deliveries, age: config.export_max_age }
    config.transport = :local
    config.export_enabled = true
    config.export_url = url
    config.export_token = token
    config.export_max_bytes = overrides.fetch(:max_bytes, previous[:bytes])
    config.export_max_deliveries = overrides.fetch(:max_deliveries, previous[:count])
    yield
  ensure
    config.transport = :http
    config.export_enabled = previous[:enabled]
    config.export_url = previous[:url]
    config.export_token = previous[:token]
    config.export_max_bytes = previous[:bytes]
    config.export_max_deliveries = previous[:count]
    config.export_max_age = previous[:age]
  end

  def ingest(records, batch_id: SecureRandom.uuid)
    Railwatch::Ingest::Batch.new(environment, records, embedded: true, batch_id: batch_id).write!
  end

  def environment = Railwatch::Environment.current

  def deliveries = environment.with_telemetry { Railwatch::Telemetry::ExportDelivery.order(:id).to_a }

  def destination = environment.with_telemetry { Railwatch::Telemetry::ExportDestination.sole }

  def request_record(**fields)
    { "v" => 1, "t" => "request", "timestamp" => Time.now.to_f, "method" => "GET", "route" => "/widgets",
      "controller" => "widgets", "action" => "index", "status_code" => 200, "duration" => 12_000,
      "stages" => { "action" => 10_000 }, "counters" => { "queries" => 1 },
      "execution_id" => SecureRandom.uuid, "_group" => Digest::MD5.hexdigest("req") }.merge(fields)
  end

  describe "admission" do
    it "queues a delivery in the same transaction as the rows it mirrors" do
      environment.with_telemetry { expect(Railwatch::Telemetry::ExportDelivery.count).to eq(0) }
      ingest([ request_record ])

      expect(deliveries.size).to eq(1)
      expect(deliveries.first.record_count).to eq(1)
      expect(deliveries.first.state).to eq("pending")
    end

    it "sends what it was given, not what it stored" do
      # An unknown record type is rejected locally but is still the receiver's
      # to judge: mirroring only what we kept would not be mirroring.
      ingest([ request_record, request_record.merge("t" => "not_a_real_type") ])

      body = deliveries.sole.body
      lines = Zlib::GzipReader.new(StringIO.new(body)).read.lines
      expect(lines.size).to eq(2)
      expect(deliveries.sole.record_count).to eq(2)
    end

    it "records on the batch why it queued, so an install can see it did" do
      ingest([ request_record ])

      ledger = environment.with_telemetry { Railwatch::Telemetry::IngestBatch.order(:id).last }
      expect(ledger.export_disposition).to eq("queued")
      expect(ledger.export_record_count).to eq(1)
    end

    it "keeps the rows when the same batch is written twice, and queues one delivery" do
      id = SecureRandom.uuid
      ingest([ request_record ], batch_id: id)
      # A replay reaching a queue that already took this selection must not
      # enqueue it a second time.
      environment.with_telemetry { Railwatch::Telemetry::IngestBatch.find_by(batch_id: id).destroy }
      ingest([ request_record ], batch_id: id)

      expect(deliveries.size).to eq(1)
    end

    it "tracks queued bytes and count on the destination" do
      ingest([ request_record ])

      expect(destination.queued_deliveries).to eq(1)
      expect(destination.queued_bytes).to eq(deliveries.sole.body_bytes)
    end
  end

  describe "capacity" do
    it "refuses new work rather than evicting work it already promised to send" do
      ingest([ request_record ])
      first = deliveries.sole

      with_export(max_deliveries: 1) { ingest([ request_record ]) }

      expect(deliveries.map(&:id)).to eq([ first.id ])
      expect(destination.counters["shed"]).to eq(1)
    end

    it "still stores the telemetry when the queue is full" do
      with_export(max_bytes: 1) do
        expect(ingest([ request_record ]).accepted).to eq(1)
      end

      expect(deliveries).to be_empty
      ledger = environment.with_telemetry { Railwatch::Telemetry::IngestBatch.order(:id).last }
      expect(ledger.export_disposition).to eq("shed_capacity")
    end
  end

  describe "identity" do
    it "gives every delivery a v7 uuid, so the receiver can age it without a header" do
      ingest([ request_record ])

      hex = deliveries.sole.delivery_id.delete("-")
      expect(hex[12]).to eq("7")
      expect("89ab").to include(hex[16])
      ms = hex[0, 12].to_i(16)
      expect(Time.at(ms / 1000.0)).to be_within(5).of(Time.now)
    end

    it "keeps one producer id for the database, across batches" do
      ingest([ request_record ])
      ingest([ request_record ])

      expect(destination.producer_id).to match(/\A[0-9a-f-]{36}\z/)
      expect(environment.with_telemetry { Railwatch::Telemetry::ExportDestination.count }).to eq(1)
    end

    it "digests the body that will actually be sent" do
      ingest([ request_record ])

      expect(deliveries.sole.body_sha256).to eq(Digest::SHA256.hexdigest(deliveries.sole.body))
    end
  end

  describe "binding" do
    it "stops sending when the token changes, rather than following it to another tenant" do
      ingest([ request_record ])
      expect(destination.state).to eq("ready")

      with_export(token: "a_different_token") { ingest([ request_record ]) }

      expect(destination.state).to eq("unauthorized")
      expect(destination.reason).to eq("credential_changed")
    end

    it "never stores the token itself" do
      ingest([ request_record ])

      expect(destination.attributes.values.map(&:to_s)).not_to include(a_string_including("rw_token"))
    end
  end

  describe "housekeeping" do
    it "gives up on a delivery that has run out of time, and frees its body" do
      ingest([ request_record ])
      outbox = described_class.new(Railwatch.config, environment)

      environment.with_telemetry do
        expect { outbox.expire!(now: Time.now + Railwatch.config.export_max_age + 60) }
          .to change { Railwatch::Telemetry::ExportDelivery.live.count }.from(1).to(0)
      end
      expect(deliveries.sole.body).to be_nil
      expect(deliveries.sole.disposition).to eq("expired")
      expect(destination.queued_bytes).to eq(0)
    end

    it "abandons everything queued when asked, without contacting anyone" do
      ingest([ request_record ])
      outbox = described_class.new(Railwatch.config, environment)

      environment.with_telemetry { expect(outbox.discard_all!).to eq(1) }
      expect(deliveries.sole.disposition).to eq("discarded")
    end

    it "forgets terminal rows once they are only history" do
      ingest([ request_record ])
      outbox = described_class.new(Railwatch.config, environment)

      environment.with_telemetry do
        outbox.discard_all!(now: Time.now - 30 * 86_400)
        expect { outbox.prune! }.to change { Railwatch::Telemetry::ExportDelivery.count }.from(1).to(0)
      end
    end
  end
end
