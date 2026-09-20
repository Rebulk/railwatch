# frozen_string_literal: true

require "spec_helper"

RSpec.describe Railwatch::Export::Sender do
  around do |example|
    config = Railwatch.config
    previous = { transport: config.transport, enabled: config.export_enabled, url: config.export_url,
                 token: config.export_token, token_value: config.token }
    config.transport = :local
    config.export_enabled = true
    config.export_url = "https://receiver.test/ingest"
    config.export_token = "rw_token"
    example.run
  ensure
    config.token = previous[:token_value]
    config.transport = previous[:transport]
    config.export_enabled = previous[:enabled]
    config.export_url = previous[:url]
    config.export_token = previous[:token]
  end

  let(:environment) { Railwatch::Environment.current }
  let(:outbox) { Railwatch::Export::Outbox.new(Railwatch.config, environment) }
  let(:client) { Railwatch::Export::Client.new(Railwatch.config) }

  def request_record
    { "v" => 1, "t" => "request", "timestamp" => Time.now.to_f, "method" => "GET", "route" => "/widgets",
      "controller" => "widgets", "action" => "index", "status_code" => 200, "duration" => 12_000,
      "stages" => { "action" => 10_000 }, "counters" => { "queries" => 1 },
      "execution_id" => SecureRandom.uuid, "_group" => Digest::MD5.hexdigest("req") }
  end

  def ingest = Railwatch::Ingest::Batch.new(environment, [ request_record ], embedded: true,
                                            batch_id: SecureRandom.uuid).write!

  def delivery = environment.with_telemetry { Railwatch::Telemetry::ExportDelivery.order(:id).last }

  def destination = environment.with_telemetry { Railwatch::Telemetry::ExportDestination.sole }

  def claim(owner: "owner-1") = environment.with_telemetry { outbox.claim!(owner: owner) }

  def finish(claim, outcome) = environment.with_telemetry { outbox.finish!(claim, outcome) }

  def outcome(disposition, status: 200, reason: nil, retry_after_at: nil)
    Railwatch::Export::Client::Outcome.new(disposition: disposition, status: status, reason: reason,
                                           retry_after_at: retry_after_at, ack: { "accepted" => 1 })
  end

  describe "claiming" do
    it "hands out the bytes and the right to finish" do
      ingest
      held = claim

      expect(held.body).to eq(delivery.body)
      expect(held.record_count).to eq(1)
      expect(delivery.state).to eq("sending")
      expect(delivery.attempts).to eq(1)
    end

    it "gives the same delivery to only one owner" do
      ingest
      first = claim(owner: "owner-1")
      second = claim(owner: "owner-2")

      expect(first).not_to be_nil
      expect(second).to be_nil
    end

    it "takes over from an owner that stopped renewing" do
      ingest
      claim(owner: "gone")

      later = Time.now + Railwatch::Export::Lease::TTL + 5
      taken = environment.with_telemetry { outbox.claim!(owner: "owner-2", now: later) }
      expect(taken).not_to be_nil
      expect(delivery.attempts).to eq(2)
    end

    it "refuses to send while the destination is paused" do
      ingest
      environment.with_telemetry do
        Railwatch::Telemetry::ExportDestination.sole.update!(state: "deferred", retry_at: Time.now + 300)
      end

      expect(claim).to be_nil
    end

    it "sends nothing while the destination is blocked on a credential change" do
      ingest
      environment.with_telemetry { Railwatch::Telemetry::ExportDestination.sole.update!(state: "unauthorized") }

      expect(claim).to be_nil
    end
  end

  describe "finishing" do
    it "marks a stored delivery done and frees its body" do
      ingest
      held = claim

      expect(finish(held, outcome(:stored))).to be(true)
      expect(delivery.disposition).to eq("acked")
      expect(delivery.body).to be_nil
      expect(destination.queued_deliveries).to eq(0)
    end

    it "keeps the bytes and comes back later when it was not stored" do
      ingest
      held = claim

      finish(held, outcome(:deferred, status: 503, reason: "busy"))

      expect(delivery.state).to eq("pending")
      expect(delivery.body).not_to be_nil
      expect(delivery.next_attempt_at).to be > Time.now
    end

    it "never comes back sooner than the receiver asked" do
      ingest
      held = claim
      asked = Time.now + 900

      finish(held, outcome(:deferred, status: 429, reason: "rate", retry_after_at: asked))

      expect(delivery.next_attempt_at).to be_within(2).of(asked)
      expect(destination.retry_at).to be_within(2).of(asked)
    end

    it "gives up on a delivery the receiver will never accept" do
      ingest
      held = claim

      finish(held, outcome(:rejected, status: 409, reason: "conflict"))

      expect(delivery.disposition).to eq("rejected")
      expect(delivery.body).to be_nil
    end

    it "stops the whole destination when the token is refused" do
      ingest
      held = claim

      finish(held, outcome(:deferred, status: 401, reason: "unauthorized"))

      expect(destination.state).to eq("unauthorized")
    end

    it "ignores a holder whose lease has been taken away" do
      ingest
      stale = claim(owner: "gone")
      later = Time.now + Railwatch::Export::Lease::TTL + 5
      environment.with_telemetry { outbox.claim!(owner: "owner-2", now: later) }

      # The stale holder's request landed anyway. The receipt at the far end
      # makes that harmless; what it must not do is overwrite the new
      # holder's row.
      expect(finish(stale, outcome(:stored))).to be(false)
      expect(delivery.state).to eq("sending")
      expect(delivery.disposition).to be_nil
    end
  end

  describe "backing off" do
    it "waits longer each time, and never in lockstep with anyone else" do
      ingest
      waits = 4.times.map do |attempt|
        at = Time.now + (attempt * 3600)
        environment.with_telemetry do
          Railwatch::Telemetry::ExportDelivery.order(:id).last.update!(attempts: attempt)
        end
        held = environment.with_telemetry { outbox.claim!(owner: "o", now: at) }
        environment.with_telemetry { outbox.finish!(held, outcome(:deferred, status: 500), now: at) }
        delivery.next_attempt_at - at
      end

      expect(waits.last).to be > waits.first
      expect(waits.uniq.size).to eq(waits.size)
    end
  end

  describe "what it refuses to throw away" do
    it "keeps the bytes when WE declined to send, rather than treating it as a rejection" do
      ingest
      held = claim
      # A latched credential failure means the delivery was never offered to
      # anyone. Freeing its body would destroy telemetry nobody refused.
      refused = Railwatch::Transport::Http::Result.new(ok: false, error: "unauthorized, flushing stopped",
                                                        status: 401, disposition: :permanent)
      finish(held, Railwatch::Export::Client.new(Railwatch.config).__send__(:interpret, refused))

      expect(delivery.state).to eq("pending")
      expect(delivery.body).not_to be_nil
    end

    it "does not believe counts that add up when the receiver named something else" do
      ingest
      stub_request(:post, "https://receiver.test/ingest")
        .to_return(status: 200, body: '{"disposition":"queued_for_review","accepted":1,"rejected":0}')

      held = claim
      finish(held, client.deliver(held, producer_id: destination.producer_id))

      expect(delivery.state).to eq("pending")
      expect(delivery.body).not_to be_nil
    end
  end

  describe "pauses that end" do
    it "comes back by itself once the receiver's delay has passed" do
      ingest
      held = claim
      finish(held, outcome(:deferred, status: 429, reason: "rate", retry_after_at: Time.now + 60))
      expect(claim).to be_nil

      later = Time.now + 120
      expect(environment.with_telemetry { outbox.claim!(owner: "o", now: later) }).not_to be_nil
    end

    it "does not pause the whole destination because one delivery got a 503" do
      ingest
      ingest
      first = claim
      finish(first, outcome(:deferred, status: 503, reason: "busy"))

      expect(destination.state).to eq("ready")
      expect(claim).not_to be_nil
    end

    it "stops saying it is paused once something gets through" do
      ingest
      ingest
      finish(claim, outcome(:deferred, status: 429, reason: "rate", retry_after_at: Time.now - 1))
      expect(destination.state).to eq("deferred")

      # Past the short backoff the failure earned, so there is something to
      # claim; the point is what a success then does to the pause.
      later = Time.now + 120
      held = environment.with_telemetry { outbox.claim!(owner: "o", now: later) }
      environment.with_telemetry { outbox.finish!(held, outcome(:stored), now: later) }
      expect(destination.state).to eq("ready")
      expect(destination.retry_at).to be_nil
    end

    it "keeps a credential block until a person clears it" do
      ingest
      finish(claim, outcome(:deferred, status: 401, reason: "unauthorized"))

      expect(environment.with_telemetry { outbox.claim!(owner: "o", now: Time.now + 86_400) }).to be_nil
    end
  end

  describe "credentials" do
    it "never sends a claimed delivery with a replacement tenant credential" do
      ingest
      held = claim
      Railwatch.config.export_token = "rw_other_tenant"
      sent = stub_request(:post, "https://receiver.test/ingest")
        .to_return(status: 200, body: '{"disposition":"committed","accepted":1,"rejected":0}')

      outcome = client.deliver(held, producer_id: held.producer_id)
      expect(sent).not_to have_been_requested
      expect(outcome.disposition).to eq(:deferred)
      expect(outcome.status).to eq(401)
      finish(held, outcome)
      expect(delivery.body).not_to be_nil
      expect(destination).to be_blocked
    end

    it "rechecks the binding even when a transport was already cached" do
      ingest
      held = claim
      sent = stub_request(:post, "https://receiver.test/ingest")
        .to_return(status: 200, body: '{"disposition":"committed","accepted":1,"rejected":0}')
      client.deliver(held, producer_id: held.producer_id)
      Railwatch.config.export_token = "rw_other_tenant"

      outcome = client.deliver(held, producer_id: held.producer_id)
      expect(sent).to have_been_requested.once
      expect(outcome.status).to eq(401)
    end

    it "authenticates with the export token, not whatever the cloud transport uses" do
      Railwatch.config.token = "ordinary_cloud_token"
      Railwatch.config.export_token = "export_only_token"
      ingest
      stub_request(:post, "https://receiver.test/ingest")
        .to_return(status: 200, body: '{"disposition":"committed","accepted":1,"rejected":0}')

      held = claim
      Railwatch::Export::Client.new(Railwatch.config).deliver(held, producer_id: destination.producer_id)

      expect(a_request(:post, "https://receiver.test/ingest")
        .with(headers: { "Authorization" => "Bearer export_only_token" })).to have_been_made
    end
  end

  describe "giving up in time" do
    it "stops waiting for a delivery that has run out of time, and frees its bytes" do
      ingest
      past = Time.now + Railwatch.config.export_max_age + 60
      environment.with_telemetry { outbox.expire!(now: past) }

      expect(delivery.disposition).to eq("expired")
      expect(delivery.body).to be_nil
    end

    it "is run by the maintenance clock, so the age limit is a limit" do
      expect(Railwatch::Maintenance::TASKS).to have_key("export_expiry")
    end
  end

  describe "what the receiver is told about this delivery" do
    it "sends the version the delivery was built by, not the one running now" do
      ingest
      environment.with_telemetry do
        row = Railwatch::Telemetry::ExportDelivery.order(:id).last
        row.update!(wire_metadata: row.wire_metadata.merge("version" => "0.0.1-old"))
      end
      stub_request(:post, "https://receiver.test/ingest")
        .to_return(status: 200, body: '{"disposition":"committed","accepted":1,"rejected":0}')

      held = claim
      client.deliver(held, producer_id: destination.producer_id)

      # The receiver digests this header and treats a change as a conflict,
      # so sending today's version would turn a gem upgrade into a 409 and
      # destroy a delivery it had already accepted.
      expect(a_request(:post, "https://receiver.test/ingest")
        .with(headers: { "X-Railwatch-Version" => "0.0.1-old" })).to have_been_made
    end

    it "posts to the destination the delivery was admitted for, not wherever config now points" do
      ingest
      held = claim
      stub_request(:post, "https://receiver.test/ingest")
        .to_return(status: 200, body: '{"disposition":"committed","accepted":1,"rejected":0}')

      # Reconfigured mid-flight. These bytes were admitted for the first
      # receiver and belong to whoever that token names.
      Railwatch.config.export_url = "https://somewhere-else.test/ingest"
      client.deliver(held, producer_id: held.producer_id)

      expect(a_request(:post, "https://receiver.test/ingest")).to have_been_made
      expect(a_request(:post, "https://somewhere-else.test/ingest")).not_to have_been_made
    end
  end

  describe "work it will not bother sending" do
    it "does not claim a delivery it has stopped waiting for" do
      ingest
      # Past its expiry but before the sweep that terminalises it: claiming
      # it would post something the receiver may no longer recognise.
      past = Time.now + Railwatch.config.export_max_age + 60
      expect(environment.with_telemetry { outbox.claim!(owner: "o", now: past) }).to be_nil
    end

    it "refuses a retry lifetime the receiver will not honour" do
      previous = Railwatch.config.export_max_age
      Railwatch.config.export_max_age = Railwatch::Configuration::MAX_EXPORT_AGE + 1

      expect(Railwatch.config.export?).to be(false)
      expect(Railwatch.config.export_problem).to include("EXPORT_MAX_AGE")
    ensure
      Railwatch.config.export_max_age = previous
    end

    it "leaves out records beyond what the receiver will accept in one request" do
      encoder = Railwatch::Transport::WireEncoder.new(batch_bytes: 64 << 20)
      records = Array.new(Railwatch::Export::Policy::Everything::MAX_RECORDS + 5) { request_record }

      selection = Railwatch::Export::Policy::Everything.prepare(
        records: records, encoder: encoder, source_batch_id: "b1"
      ).sole

      # A request over the receiver's ceiling is refused whole, so the excess
      # is counted as dropped here rather than costing the whole delivery.
      expect(selection.record_count).to eq(Railwatch::Export::Policy::Everything::MAX_RECORDS)
      expect(selection.metadata["dropped"]).to eq(5)
    end
  end

  describe "the whole round trip" do
    it "sends a queued delivery and marks it acknowledged" do
      ingest
      stub_request(:post, "https://receiver.test/ingest")
        .to_return(status: 200, body: '{"disposition":"committed","accepted":1,"rejected":0}')

      held = claim
      result = client.deliver(held, producer_id: destination.producer_id)
      finish(held, result)

      expect(delivery.disposition).to eq("acked")
      expect(a_request(:post, "https://receiver.test/ingest")
        .with(headers: { "X-Railwatch-Producer-Id" => destination.producer_id,
                         "X-Railwatch-Batch-Id" => held.delivery_id })).to have_been_made
    end

    it "treats a delivery the receiver already holds as done" do
      ingest
      stub_request(:post, "https://receiver.test/ingest")
        .to_return(status: 200, body: '{"disposition":"already_committed","accepted":1,"rejected":0}')

      held = claim
      finish(held, client.deliver(held, producer_id: destination.producer_id))

      expect(delivery.disposition).to eq("acked")
    end

    it "keeps the delivery when the receiver never answered" do
      ingest
      stub_request(:post, "https://receiver.test/ingest").to_timeout

      held = claim
      finish(held, client.deliver(held, producer_id: destination.producer_id))

      expect(delivery.state).to eq("pending")
      expect(delivery.body).not_to be_nil
    end

    it "sends the same bytes on a retry, so it stays the same delivery" do
      ingest
      bodies = []
      stub_request(:post, "https://receiver.test/ingest").to_return do |request|
        bodies << request.body.b
        { status: 500, body: "boom" }
      end

      2.times do
        held = environment.with_telemetry { outbox.claim!(owner: "o", now: Time.now + 3600) }
        finish(held, client.deliver(held, producer_id: destination.producer_id))
      end

      expect(bodies.size).to eq(2)
      expect(bodies.uniq.size).to eq(1)
    end
  end
end
