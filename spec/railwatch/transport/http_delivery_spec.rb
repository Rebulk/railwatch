# frozen_string_literal: true

require "spec_helper"
require "socket"
require "timeout"

RSpec.describe Railwatch::Transport::Http do
  let(:transport) { described_class.new(Railwatch.config) }

  describe "what the receiver said" do
    it "stops reading a chunked response as soon as it exceeds the cap" do
      response = Net::HTTPOK.new("1.1", "200", "OK")
      allow(response).to receive(:read_body) do |&consume|
        consume.call("x" * described_class::MAX_RESPONSE_BYTES)
        consume.call("x")
        raise "read beyond the response ceiling"
      end
      http = instance_double(Net::HTTP)
      allow(http).to receive(:request).and_yield(response)
      allow(Net::HTTP).to receive(:start).and_yield(http)

      result = transport.deliver_encoded(body: "batch", expected_count: 1, batch_id: "one")
      expect(result).to be_retryable
      expect(result.error).to include("ResponseTooLarge")
      expect(result.error).not_to include("read beyond")
    end

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

    it "keeps only the first slice of an enormous error page" do
      stub_request(:post, "http://railwatch.test/ingest").to_return(status: 502, body: "x" * 200_000)

      expect(transport.deliver([ { "t" => "request" } ]).error.bytesize).to be <= 200
    end

    it "refuses an oversized acknowledgement whole, rather than parsing a prefix of it" do
      # A truncated prefix can be valid JSON that says something the receiver
      # did not: pad a complete document with spaces and follow it with junk.
      padded = '{"accepted":1,"rejected":0}'.ljust(described_class::MAX_RESPONSE_BYTES, " ") + "GARBAGE"
      stub_request(:post, "http://railwatch.test/ingest").to_return(status: 200, body: padded)

      result = transport.deliver([ { "t" => "request" } ])

      expect(result.ok).to be(false)
      expect(result.error).to include("larger than")
    end

    it "does not quote the response body back into an error a caller may log" do
      stub_request(:post, "http://railwatch.test/ingest")
        .to_return(status: 200, body: '{"accepted": Bearer rw_secret_token')

      expect(transport.deliver([ { "t" => "request" } ]).error).not_to include("rw_secret_token")
    end

    it "accepts an HTTP-date Retry-After" do
      at = (Time.now + 120).httpdate
      stub_request(:post, "http://railwatch.test/ingest")
        .to_return(status: 429, body: "wait", headers: { "Retry-After" => at })

      expect(transport.deliver([ { "t" => "request" } ]).retry_after_at).to be_within(2).of(Time.httpdate(at))
    end

    # WebMock replaces Net::HTTP, and the response head is read inside it,
    # so these need a real socket. The receiver reads the request, then
    # answers with whatever the example writes.
    def with_receiver(answer)
      server = TCPServer.new("127.0.0.1", 0)
      thread = Thread.new do
        socket = server.accept
        head = +""
        head << socket.readpartial(65_536) until head.include?("\r\n\r\n")
        length = head[/^content-length: *(\d+)/i, 1].to_i
        body_read = head.split("\r\n\r\n", 2).last.bytesize
        socket.read(length - body_read) if length > body_read
        answer.call(socket)
      rescue StandardError
        nil
      ensure
        socket&.close
      end
      WebMock.allow_net_connect!
      yield "http://127.0.0.1:#{server.addr[1]}"
    ensure
      WebMock.disable_net_connect!
      thread&.kill
      server&.close
    end

    def local_transport(url, timeout: 0.1)
      config = Railwatch.config.dup
      config.ingest_url = url
      config.connect_timeout = timeout
      config.timeout = timeout
      described_class.new(config)
    end

    it "refuses a response head larger than the body cap many times over" do
      pad = "a" * (2 * 1024 * 1024)
      ack = '{"accepted":1,"rejected":0}'
      answer = ->(socket) { socket.write("HTTP/1.1 200 OK\r\nX-Pad: #{pad}\r\nContent-Length: #{ack.bytesize}\r\n\r\n#{ack}") }

      result = with_receiver(answer) { |url| local_transport(url, timeout: 2).deliver([ { "t" => "request" } ]) }

      expect(result.ok).to be(false)
      expect(result).to be_retryable
      expect(result.error).to match(/too long/)
    end

    it "gives up on a receiver that drips its response out under the per-read timeout" do
      answer = lambda do |socket|
        socket.write("HTTP/1.1 200 OK\r\n")
        loop do
          socket.write("X")
          sleep 0.02
        end
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = with_receiver(answer) do |url|
        Timeout.timeout(8) { local_transport(url).deliver([ { "t" => "request" } ]) }
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(result.ok).to be(false)
      expect(result).to be_retryable
      expect(result.error).to include("DeliveryTimeout")
      expect(elapsed).to be < 5
    end

    it "refuses a Retry-After further out than it is willing to wait, in either spelling" do
      stub_request(:post, "http://railwatch.test/ingest")
        .to_return(status: 429, body: "wait", headers: { "Retry-After" => (Time.now + 400.0 * 86_400).httpdate })

      expect(transport.deliver([ { "t" => "request" } ]).retry_after_at).to be_nil
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

      result = transport.deliver_encoded(body: encoded.body, expected_count: 1, batch_id: "d-1")

      expect(result.ok).to be(true)
      expect(sent.b).to eq(encoded.body)
    end

    it "makes exactly one attempt, so it cannot multiply its caller's backoff" do
      stub_request(:post, "http://railwatch.test/ingest").to_return(status: 500, body: "boom")

      transport.deliver_encoded(body: encoded.body, expected_count: 1, batch_id: "d-1")

      expect(a_request(:post, "http://railwatch.test/ingest")).to have_been_made.once
    end

    it "makes exactly one attempt when the connection fails outright" do
      stub_request(:post, "http://railwatch.test/ingest").to_raise(Net::OpenTimeout)

      result = transport.deliver_encoded(body: encoded.body, expected_count: 1, batch_id: "d-1")

      expect(result).to be_retryable
      expect(a_request(:post, "http://railwatch.test/ingest")).to have_been_made.once
    end

    it "passes the headers that name the delivery" do
      stub_request(:post, "http://railwatch.test/ingest").to_return(status: 200, body: '{"accepted":1,"rejected":0}')

      transport.deliver_encoded(body: encoded.body, expected_count: 1, batch_id: "d-1",
                                headers: { "X-Railwatch-Producer-Id" => "p1" })

      expect(a_request(:post, "http://railwatch.test/ingest")
        .with(headers: { "X-Railwatch-Producer-Id" => "p1" })).to have_been_made
    end

    it "posts to an explicit endpoint when one is configured, path and all" do
      custom = described_class.new(Railwatch.config, endpoint: "http://railwatch.test/prefix/ingest")
      stub_request(:post, "http://railwatch.test/prefix/ingest")
        .to_return(status: 200, body: '{"accepted":1,"rejected":0}')

      expect(custom.deliver_encoded(body: encoded.body, expected_count: 1, batch_id: "d-1").ok).to be(true)
    end

    it "refuses plain HTTP without making a request, like every other send" do
      config = Railwatch.config.dup
      config.ingest_url = "http://elsewhere.test"
      config.allow_http = false
      blocked = described_class.new(config)

      result = blocked.deliver_encoded(body: encoded.body, expected_count: 1, batch_id: "d-1")

      expect(result.ok).to be(false)
      expect(result).not_to be_retryable
      expect(a_request(:post, "http://elsewhere.test/ingest")).not_to have_been_made
    end

    it "judges the endpoint it will actually POST to, not some other configured URL" do
      # Otherwise an HTTPS ingest_url would vouch for a plaintext endpoint and
      # put the bearer token on the wire in the clear.
      config = Railwatch.config.dup
      config.ingest_url = "https://railwatch.test"
      config.allow_http = false
      leaky = described_class.new(config, endpoint: "http://elsewhere.test/ingest")

      result = leaky.deliver_encoded(body: encoded.body, expected_count: 1, batch_id: "d-1")

      expect(result.ok).to be(false)
      expect(a_request(:post, "http://elsewhere.test/ingest")).not_to have_been_made
    end

    it "stops sending once the receiver has refused the token" do
      stub_request(:post, "http://railwatch.test/ingest").to_return(status: 401, body: "nope")

      transport.deliver_encoded(body: encoded.body, expected_count: 1, batch_id: "d-1")
      second = transport.deliver_encoded(body: encoded.body, expected_count: 1, batch_id: "d-2")

      expect(second.status).to eq(401)
      expect(a_request(:post, "http://railwatch.test/ingest")).to have_been_made.once
    end

    it "marks bad input permanent rather than asking its caller to retry forever" do
      result = transport.deliver_encoded(body: encoded.body, expected_count: 1, batch_id: "d-1",
                                         headers: { "X-Railwatch-Producer-Id" => "has\nnewline" })

      expect(result.ok).to be(false)
      expect(result).not_to be_retryable
      expect(result.disposition).to eq(:permanent)
    end
  end
end
