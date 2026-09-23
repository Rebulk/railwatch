# frozen_string_literal: true

require "spec_helper"
require "socket"

# How fast the export queue can drain, and what it may not give up to do so.
#
# Production (gem 0.3.4, embedded + export): one delivery per source batch,
# a median of one record and ~640 gzip bytes, sent one per round trip, and a
# round trip was ~500 ms -- 270 ms of it reclaim_abandoned scanning every row
# the destination ever had (344k, 330k of them done) under the write lock,
# and ~240 ms a fresh TCP+TLS handshake. That is ~120 deliveries a minute
# against a normal load of ~70; an incident that doubled the load built a
# 14,600-delivery backlog that took hours to clear.
RSpec.describe "export throughput" do
  around do |example|
    config = Railwatch.config
    previous = { transport: config.transport, enabled: config.export_enabled, url: config.export_url,
                 token: config.export_token }
    config.transport = :local
    config.export_enabled = true
    config.export_url = "https://receiver.test/ingest"
    config.export_token = "rw_token"
    example.run
  ensure
    config.transport = previous[:transport]
    config.export_enabled = previous[:enabled]
    config.export_url = previous[:url]
    config.export_token = previous[:token]
  end

  let(:environment) { Railwatch::Environment.current }
  let(:outbox) { Railwatch::Export::Outbox.new(Railwatch.config, environment) }
  let(:client) { Railwatch::Export::Client.new(Railwatch.config) }

  def telemetry(&) = environment.with_telemetry(&)

  def request_record(i = 0)
    { "v" => 1, "t" => "request", "timestamp" => Time.now.to_f, "method" => "GET", "route" => "/widgets/#{i}",
      "controller" => "widgets", "action" => "index", "status_code" => 200, "duration" => 12_000,
      "stages" => { "action" => 10_000 }, "counters" => { "queries" => 1 },
      "execution_id" => SecureRandom.uuid, "_group" => Digest::MD5.hexdigest("req") }
  end

  def ingest(records = [ request_record ], batch_id: SecureRandom.uuid, dropped: 0)
    Railwatch::Ingest::Batch.new(environment, records, embedded: true, batch_id: batch_id,
                                 dropped_by_client: dropped).write!
  end

  def deliveries = telemetry { Railwatch::Telemetry::ExportDelivery.order(:id).to_a }

  def destination = telemetry { Railwatch::Telemetry::ExportDestination.sole }

  def lines(body) = Zlib.gunzip(body).lines.map { |line| JSON.parse(line) }

  # A receiver that keeps receipts the way railwatch-cloud does: a delivery
  # id it has committed is answered "already_committed" and not written
  # again; the same id with other bytes is a 409.
  def stub_receiver(fail_first: 0)
    stored = {}
    requests = []
    stub_request(:post, "https://receiver.test/ingest").to_return do |request|
      requests << request
      next { status: 503, body: "busy" } if requests.size <= fail_first

      id = request.headers["X-Railwatch-Batch-Id"]
      sha = request.headers["X-Railwatch-Body-Sha256"]
      records = lines(request.body.b)
      if (previous = stored[id])
        next { status: 409, body: "conflict" } unless previous[:sha] == sha

        next { status: 200, body: JSON.generate(disposition: "already_committed", accepted: previous[:records].size, rejected: 0) }
      end
      stored[id] = { sha: sha, records: records }
      { status: 200, body: JSON.generate(disposition: "committed", accepted: records.size, rejected: 0) }
    end
    [ stored, requests ]
  end

  # The sender's loop, without its thread and waits.
  def drain(owner: "owner-1", limit: 10_000)
    limit.times do
      sent = Railwatch::Export::Sender.instance_variable_set(:@owner, owner) &&
             Railwatch::Export::Sender.drain_one
      break unless sent
    end
  end

  before do
    Railwatch::Export::Sender.instance_variable_set(:@client, client)
  end

  after do
    Railwatch::Export::Sender.instance_variable_set(:@client, nil)
    Railwatch::Export::Sender.instance_variable_set(:@owner, nil)
  end

  describe "coalescing a backlog" do
    it "drains 1,000 one-record deliveries in a handful of round trips, every record exactly once, oldest first" do
      ids = Array.new(1_000) { |i| request_record(i) }.each { |record| ingest([ record ]) }.map { |r| r["execution_id"] }
      stored, requests = stub_receiver

      drain

      received = stored.values.flat_map { |delivery| delivery[:records] }
      # Before this change: 1,000 requests, one per delivery.
      expect(requests.size).to eq(2)
      expect(received.map { |r| r["execution_id"] }).to eq(ids)
      expect(deliveries.map(&:state).uniq).to eq([ "done" ])
      expect(deliveries.map(&:disposition).tally).to eq("acked" => 2, "merged" => 998)
      expect(destination.queued_deliveries).to eq(0)
      expect(destination.queued_bytes).to eq(0)
      expect(destination.counters).to include("acked" => 2, "merged" => 998)
    end

    it "sends a queue that keeps up exactly as before: one delivery, untouched" do
      ingest
      original = deliveries.sole
      _stored, requests = stub_receiver

      drain

      expect(requests.size).to eq(1)
      expect(requests.sole.body.b).to eq(original.body)
      expect(requests.sole.headers["X-Railwatch-Batch-Id"]).to eq(original.delivery_id)
    end

    it "adds up what the merged batches reported losing, and keeps the highest backpressure" do
      ingest([ request_record ], dropped: 3)
      ingest([ request_record ], dropped: 4)
      telemetry do
        row = Railwatch::Telemetry::ExportDelivery.order(:id).last
        row.update!(wire_metadata: row.wire_metadata.merge("backpressure_factor" => "4.0"))
      end
      _stored, requests = stub_receiver

      drain

      expect(requests.size).to eq(1)
      expect(requests.sole.headers["X-Railwatch-Dropped"]).to eq("7")
      expect(requests.sole.headers["X-Railwatch-Backpressure-Factor"]).to eq("4.0")
    end

    it "never merges past the record cap the receiver is used to" do
      3.times { ingest(Array.new(300) { |i| request_record(i) }) }
      _stored, requests = stub_receiver

      drain

      # 300 + 300 would be over 500, so each goes alone.
      expect(requests.size).to eq(3)
      expect(requests.map { |r| lines(r.body.b).size }).to eq([ 300, 300, 300 ])
    end

    it "does not merge deliveries built by different gem versions" do
      ingest
      telemetry do
        row = Railwatch::Telemetry::ExportDelivery.order(:id).last
        row.update!(wire_metadata: row.wire_metadata.merge("version" => "0.0.1-old"))
      end
      ingest
      _stored, requests = stub_receiver

      drain

      expect(requests.map { |r| r.headers["X-Railwatch-Version"] }).to eq([ "0.0.1-old", Railwatch::VERSION ])
    end

    it "leaves the delivery a stale lease holder still has in flight alone" do
      3.times { ingest }
      stale = telemetry { outbox.claim!(owner: "gone") }

      merged = telemetry { outbox.coalesce!(owner: "owner-2", now: Time.now + Railwatch::Export::Lease::TTL + 5) }

      # The row it holds is not pending, so the merge started behind it and
      # its bytes -- which may already be at the receiver -- are untouched.
      expect(merged).to eq(1)
      held = telemetry { Railwatch::Telemetry::ExportDelivery.find(stale.id) }
      expect(held.state).to eq("sending")
      expect(held.body).to eq(stale.body)
      expect(held.record_count).to eq(1)
      # The generation moved on, so the next claim reclaims it and fences the
      # stale holder out (Outbox#finish! then refuses it).
      expect(destination.lease_generation).to be > stale.generation
    end

    it "does nothing while another process holds the lease" do
      3.times { ingest }
      telemetry { Railwatch::Export::Lease.acquire(destination.id, owner: "other") }

      expect(telemetry { outbox.coalesce!(owner: "owner-1") }).to eq(0)
      expect(deliveries.map(&:state).uniq).to eq([ "pending" ])
    end
  end

  describe "retries and receipts" do
    it "never rewrites a delivery that has been on the wire: a retry is the same id and the same bytes" do
      3.times { ingest }
      stored, requests = stub_receiver(fail_first: 1)

      drain
      # The first attempt failed after merging; its backoff has to pass.
      later = Time.now + 120
      held = telemetry { outbox.claim!(owner: "owner-1", now: later) }
      telemetry { outbox.finish!(held, client.deliver(held, producer_id: destination.producer_id), now: later) }

      expect(requests.size).to eq(2)
      expect(requests.map { |r| r.headers["X-Railwatch-Batch-Id"] }.uniq.size).to eq(1)
      expect(requests.map { |r| r.body.b }.uniq.size).to eq(1)
      expect(stored.values.flat_map { |d| d[:records] }.size).to eq(3)
      expect(deliveries.map(&:disposition).tally).to eq("acked" => 1, "merged" => 2)
    end

    it "does not fold new work into a delivery that failed, so its retry cannot become a conflict" do
      2.times { ingest }
      _stored, requests = stub_receiver(fail_first: 1)
      drain
      failed = deliveries.find { |d| d.state == "pending" }
      2.times { ingest }

      later = Time.now + 120
      telemetry { outbox.coalesce!(owner: "owner-1", now: later) }

      retried = telemetry { Railwatch::Telemetry::ExportDelivery.find(failed.id) }
      expect(retried.body).to eq(failed.body)
      expect(retried.body_sha256).to eq(failed.body_sha256)
      expect(retried.record_count).to eq(2)
      # And the two behind it could not merge past it, but merged together.
      expect(deliveries.count { |d| d.state == "pending" }).to eq(2)
      expect(requests.size).to eq(1)
    end

    it "answers a replayed source batch as already queued, even after its delivery was merged away" do
      batch_id = SecureRandom.uuid
      ingest(batch_id: batch_id)
      ingest
      telemetry { outbox.coalesce!(owner: "owner-1") }

      selection = Railwatch::Export::Policy::Everything.prepare(
        records: [ request_record ], encoder: Railwatch::Transport::WireEncoder.new(batch_bytes: 1 << 20),
        source_batch_id: batch_id
      )
      admission = telemetry { Railwatch::Telemetry::ExportDelivery.transaction { outbox.enqueue!(selection) } }

      expect(admission.disposition).to eq("queued")
      expect(admission.record_count).to eq(0)
      expect(deliveries.size).to eq(2)
    end
  end

  describe "the queries inside every claim" do
    def seed_done_rows(count)
      telemetry do
        dest = Railwatch::Telemetry::ExportDestination.sole
        now = Time.current
        Railwatch::Telemetry::ExportDelivery.insert_all(Array.new(count) do |i|
          { export_destination_id: dest.id, delivery_id: SecureRandom.uuid, selection_key: "old:#{i}",
            body_sha256: "0" * 64, metadata_sha256: "0" * 64, body_bytes: 600, ndjson_bytes: 900, record_count: 1,
            wire_metadata: {}, state: "done", disposition: "acked", enqueued_at: now, expires_at: now,
            next_attempt_at: now, finished_at: now, created_at: now, updated_at: now }
        end)
      end
    end

    # Every statement claim!, coalesce! and release_lease! run against the
    # delivery table, with SQLite's plan for it, binds included -- a partial
    # index only applies when the query repeats its WHERE term as a literal.
    def plans_during
      plans = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
        sql = event.payload[:sql]
        next unless sql.match?(/\A\s*(SELECT|UPDATE)/) && sql.include?("export_deliveries")
        next if sql.match?(/WHERE "export_deliveries"\."id" = \?/) # a row named by primary key

        conn = event.payload[:connection]
        plan = conn.select_rows("EXPLAIN QUERY PLAN #{sql}", "EXPLAIN", event.payload[:binds] || []).map(&:last).join(" | ")
        plans << [ sql[0, 80], plan ]
      end
      yield
      plans
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    it "reads only what is queued or in flight, never every row the destination has ever had" do
      2.times { ingest }
      seed_done_rows(5_000)

      plans = plans_during do
        telemetry do
          outbox.coalesce!(owner: "owner-1")
          outbox.claim!(owner: "owner-1")
          outbox.release_lease!(owner: "owner-1")
        end
      end

      # Production before: reclaim_abandoned alone was 270 ms of a ~500 ms
      # delivery, a walk of index_export_deliveries_on_export_destination_id
      # over 344k rows.
      # Rows named by id (coalesce!'s recheck of what it read) are primary
      # key lookups; everything else goes through a partial index.
      expect(plans.map(&:last)).to all(match(/index_export_deliveries_(live|sending)|INTEGER PRIMARY KEY/))
      expect(plans.map(&:last).join).not_to include("index_export_deliveries_on_export_destination_id")
      reclaim = plans.find { |sql, _| sql.start_with?("UPDATE") }
      expect(reclaim.last).to include("index_export_deliveries_sending")
    end
  end

  describe "the connection" do
    # A real socket: WebMock fakes Net::HTTP's connection, so it cannot tell
    # a reused connection from a new one.
    def with_receiver
      server = TCPServer.new("127.0.0.1", 0)
      accepted = 0
      thread = Thread.new do
        loop do
          sock = server.accept
          accepted += 1
          Thread.new(sock) do |conn|
            loop do
              head = +""
              while (line = conn.gets) && line != "\r\n"
                head << line
              end
              break if line.nil?

              length = head[/content-length: (\d+)/i, 1].to_i
              records = Zlib.gunzip(conn.read(length)).lines.size
              body = JSON.generate(disposition: "committed", accepted: records, rejected: 0)
              conn.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" \
                         "Content-Length: #{body.bytesize}\r\n\r\n#{body}")
            end
          ensure
            conn.close
          end
        rescue IOError
          break
        end
      end
      yield "http://127.0.0.1:#{server.addr[1]}/ingest", -> { accepted }
    ensure
      server&.close
      thread&.kill
    end

    it "sends consecutive deliveries over one connection" do
      WebMock.allow_net_connect!
      with_receiver do |url, accepted|
        Railwatch.config.export_url = url
        5.times { |i| ingest([ request_record(i) ]) }
        5.times do
          held = telemetry { outbox.claim!(owner: "owner-1") }
          outcome = client.deliver(held, producer_id: destination.producer_id)
          expect(outcome.disposition).to eq(:stored)
          telemetry { outbox.finish!(held, outcome) }
        end

        expect(accepted.call).to eq(1)
      end
    ensure
      client.close
      WebMock.disable_net_connect!
    end

    it "opens a fresh connection after a failed request rather than reusing a broken one" do
      transport = Railwatch::Transport::Http.new(Railwatch.config, endpoint: "https://receiver.test/ingest",
                                                 persistent: true)
      stub_request(:post, "https://receiver.test/ingest").to_timeout.then
        .to_return(status: 200, body: '{"disposition":"committed","accepted":1,"rejected":0}')

      failed = transport.deliver_encoded(body: Zlib.gzip("{}\n"), expected_count: 1, batch_id: SecureRandom.uuid)
      expect(failed.ok).to be(false)
      expect(transport.instance_variable_get(:@session)).to be_nil
      ok = transport.deliver_encoded(body: Zlib.gzip("{}\n"), expected_count: 1, batch_id: SecureRandom.uuid)
      expect(ok.ok).to be(true)
      # One attempt per call, still: the failure was not re-sent.
      expect(a_request(:post, "https://receiver.test/ingest")).to have_been_made.twice
    end
  end
end
