# frozen_string_literal: true

require "spec_helper"

RSpec.describe Railwatch::Transport::Http do
  let(:transport) { described_class.new(Railwatch.config) }

  describe "what the receiver said" do
    it "keeps a paused answer off the retry ladder but stops calling it storage" do
      stub_request(:post, "http://railwatch.test/ingest")
        .to_return(status: 200, body: '{"accepted":0,"rejected":0,"reason":"paused"}')

      result = transport.deliver([ { "t" => "request" } ])

      # Still delivered -- the receiver decided its fate, and retrying would
      # burn the ladder and drop the records anyway -- but the caller can now
      # tell that nothing was stored, and why.
      expect(result.ok).to be(true)
      expect(result.reason).to eq("paused")
      expect(result).to be_deferred
    end

    it "refuses an all-zero acknowledgement with no reason, which cannot describe a real batch" do
      stub_request(:post, "http://railwatch.test/ingest")
        .to_return(status: 200, body: '{"accepted":0,"rejected":0}')

      result = transport.deliver([ { "t" => "request" } ])

      expect(result.ok).to be(false)
      expect(result).to be_retryable
      expect(result.error).to include("expected 1")
    end

    it "accepts an all-zero acknowledgement for an empty batch" do
      stub_request(:post, "http://railwatch.test/ingest")
        .to_return(status: 200, body: '{"accepted":0,"rejected":0}')

      expect(transport.deliver([]).ok).to be(true)
    end

    it "carries Retry-After from an error so a caller with durable storage can honour it" do
      stub_request(:post, "http://railwatch.test/ingest")
        .to_return(status: 429, body: "slow down", headers: { "Retry-After" => "42" })

      expect(transport.deliver([ { "t" => "request" } ]).retry_after_at).to be_within(2).of(Time.now + 42)
    end

    it "ignores a Retry-After it cannot trust rather than inventing a delay" do
      stub_request(:post, "http://railwatch.test/ingest")
        .to_return(status: 503, body: "busy", headers: { "Retry-After" => "not-a-delay" })

      expect(transport.deliver([ { "t" => "request" } ]).retry_after_at).to be_nil
    end

    it "reads only the first slice of an enormous error page" do
      stub_request(:post, "http://railwatch.test/ingest").to_return(status: 502, body: "x" * 200_000)

      expect(transport.deliver([ { "t" => "request" } ]).error.bytesize).to be <= 200
    end
  end

  describe "#deliver_encoded" do
    let(:encoded) { Railwatch::Transport::WireEncoder.new(batch_bytes: 1 << 20).encode([ { "t" => "request" } ]) }

    it "sends the bytes it was given, unchanged" do
      sent = nil
      stub_request(:post, "http://railwatch.test/ingest").to_return do |request|
        sent = request.body
        { status: 200, body: '{"accepted":1,"rejected":0}' }
      end

      result = transport.deliver_encoded(body: encoded.body, expected_count: 1)

      expect(result.ok).to be(true)
      expect(sent.b).to eq(encoded.body)
    end

    it "makes exactly one attempt, so it cannot multiply its caller's backoff" do
      stub_request(:post, "http://railwatch.test/ingest").to_return(status: 500, body: "boom")

      transport.deliver_encoded(body: encoded.body, expected_count: 1)

      expect(a_request(:post, "http://railwatch.test/ingest")).to have_been_made.once
    end

    it "makes exactly one attempt when the connection fails outright" do
      stub_request(:post, "http://railwatch.test/ingest").to_raise(Net::OpenTimeout)

      result = transport.deliver_encoded(body: encoded.body, expected_count: 1)

      expect(result).to be_retryable
      expect(a_request(:post, "http://railwatch.test/ingest")).to have_been_made.once
    end

    it "passes the headers that name the delivery" do
      stub_request(:post, "http://railwatch.test/ingest").to_return(status: 200, body: '{"accepted":1,"rejected":0}')

      transport.deliver_encoded(body: encoded.body, expected_count: 1,
                                headers: { "X-Railwatch-Producer-Id" => "p1" })

      expect(a_request(:post, "http://railwatch.test/ingest")
        .with(headers: { "X-Railwatch-Producer-Id" => "p1" })).to have_been_made
    end

    it "posts to an explicit endpoint when one is configured, path and all" do
      custom = described_class.new(Railwatch.config, endpoint: "http://railwatch.test/prefix/ingest")
      stub_request(:post, "http://railwatch.test/prefix/ingest")
        .to_return(status: 200, body: '{"accepted":1,"rejected":0}')

      expect(custom.deliver_encoded(body: encoded.body, expected_count: 1).ok).to be(true)
    end

    it "refuses plain HTTP without making a request, like every other send" do
      config = Railwatch.config.dup
      config.ingest_url = "http://elsewhere.test"
      config.allow_http = false
      blocked = described_class.new(config)

      expect(blocked.deliver_encoded(body: encoded.body, expected_count: 1).ok).to be(false)
      expect(a_request(:post, "http://elsewhere.test/ingest")).not_to have_been_made
    end
  end
end
