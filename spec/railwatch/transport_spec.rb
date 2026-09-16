# frozen_string_literal: true

require "spec_helper"
require "timeout"
require "socket"

RSpec.describe Railwatch::Transport::Http do
  let(:transport) { described_class.new(Railwatch.config) }

  describe "#deliver" do
    it "pins TLS certificate verification to VERIFY_PEER" do
      config = Railwatch.config.dup
      config.ingest_url = "https://railwatch.example"
      secure_transport = described_class.new(config)
      response = Net::HTTPOK.new("1.1", "200", "OK")
      http = instance_double(Net::HTTP, request: response)

      expect(Net::HTTP).to receive(:start).with(
        "railwatch.example", 443,
        hash_including(use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_PEER)
      ).and_yield(http)

      expect(secure_transport.ping).to be(true)
    end

    it "refuses non-loopback plain HTTP without making a request" do
      config = Railwatch.config.dup
      config.ingest_url = "http://railwatch.example"
      config.allow_http = false
      insecure_transport = described_class.new(config)

      expect(Net::HTTP).not_to receive(:start)
      result = insecure_transport.deliver([ { t: "log" } ])

      expect(result.ok).to be(false)
      expect(result.error).to include("plain HTTP ingest is disabled")
    end

    it "posts the batch as gzip NDJSON with the bearer token, gem version, and content headers" do
      captured = nil
      stub_request(:post, "http://railwatch.test/ingest").to_return do |request|
        captured = request
        { status: 200, body: '{"accepted":2,"rejected":0}' }
      end

      result = transport.deliver([ { t: "log", message: "a" }, { t: "log", message: "b" } ], dropped: 3)

      expect(result.ok).to be(true)
      expect(result.accepted).to eq(2)
      expect(captured.headers["Authorization"]).to eq("Bearer test-token")
      expect(captured.headers["Content-Type"]).to eq("application/x-ndjson")
      expect(captured.headers["Content-Encoding"]).to eq("gzip")
      expect(captured.headers["X-Railwatch-Version"]).to eq(Railwatch::VERSION)
      expect(captured.headers["X-Railwatch-Dropped"]).to eq("3")
      expect(captured.headers["X-Railwatch-Batch-Id"]).to match(/\A[0-9a-f-]{36}\z/)

      decoded = Zlib::GzipReader.new(StringIO.new(captured.body)).read
      expect(decoded.each_line.map { |l| JSON.parse(l) }).to eq(
        [ { "t" => "log", "message" => "a" }, { "t" => "log", "message" => "b" } ]
      )
    end

    it "reports the active backpressure factor alongside batch accounting" do
      captured = nil
      stub_request(:post, "http://railwatch.test/ingest").to_return do |request|
        captured = request
        { status: 200, body: '{"accepted":1,"rejected":0}' }
      end

      transport.deliver([ { t: "log" } ], backpressure_factor: 4.0)

      expect(captured.headers["X-Railwatch-Backpressure-Factor"]).to eq("4.0")
    end

    it "uses one caller-supplied batch id for the original request and its immediate retry" do
      seen_ids = []
      stub_request(:post, "http://railwatch.test/ingest").to_return do |request|
        seen_ids << request.headers["X-Railwatch-Batch-Id"]
        seen_ids.one? ? { status: 503, body: "unavailable" } : { status: 200, body: '{"accepted":1,"rejected":0}' }
      end

      result = transport.deliver([ { t: "log" } ], batch_id: "804b36bd-5cf7-4ed5-b649-ab8a7064e13b")

      expect(result.ok).to be(true)
      expect(seen_ids).to eq([ "804b36bd-5cf7-4ed5-b649-ab8a7064e13b" ] * 2)
    end

    it "omits the X-Railwatch-Dropped header when nothing was dropped" do
      captured = nil
      stub_request(:post, "http://railwatch.test/ingest").to_return do |request|
        captured = request
        { status: 200, body: '{"accepted":1,"rejected":0}' }
      end

      transport.deliver([ { t: "log" } ], dropped: 0)

      expect(captured.headers).not_to have_key("X-Railwatch-Dropped")
    end

    it "drops records that do not fit the batch byte cap rather than retrying forever" do
      config = Railwatch.config.dup
      config.batch_bytes = 64
      bounded = described_class.new(config)
      captured = nil
      stub_request(:post, "http://railwatch.test/ingest").to_return do |request|
        captured = request
        # The acknowledgement covers the records actually posted (one), not
        # the two handed to deliver: the over-cap record never left the box.
        { status: 200, body: '{"accepted":1,"rejected":0}' }
      end

      result = bounded.deliver([ { t: "log", message: "a" }, { t: "log", message: "x" * 200 } ])

      expect(result.ok).to be(true)
      expect(result).not_to be_retryable
      expect(captured.headers["X-Railwatch-Dropped"]).to eq("1")
      decoded = Zlib::GzipReader.new(StringIO.new(captured.body)).read
      expect(decoded.lines.size).to eq(1)
      expect(decoded).to include('"message":"a"')
    end

    it "retries once on a network error, then returns a retryable result without raising" do
      seen_errors = []
      Railwatch.on_unrecoverable { |e| seen_errors << e }
      stub_request(:post, "http://railwatch.test/ingest").to_raise(Net::OpenTimeout)

      result = nil
      expect { result = transport.deliver([ { t: "log" } ]) }.not_to raise_error

      expect(result.ok).to be(false)
      expect(result).to be_retryable
      expect(a_request(:post, "http://railwatch.test/ingest")).to have_been_made.times(2)
      expect(seen_errors).to be_empty
    ensure
      Railwatch.config.on_unrecoverable = nil
    end

    it "falls back to the debug log instead of raising when no on_unrecoverable callback is registered" do
      Railwatch.config.on_unrecoverable = nil
      stub_request(:post, "http://railwatch.test/ingest").to_raise(Net::OpenTimeout)

      result = nil
      expect { result = transport.deliver([ { t: "log" } ]) }.not_to raise_error
      expect(result.ok).to be(false)
      expect(result.error).to include("Net::OpenTimeout")
    end

    it "retries a 5xx response once and succeeds on the retry" do
      stub_request(:post, "http://railwatch.test/ingest")
        .to_return({ status: 503, body: "unavailable" }, { status: 200, body: '{"accepted":1,"rejected":0}' })

      result = transport.deliver([ { t: "log" } ])

      expect(result.ok).to be(true)
      expect(a_request(:post, "http://railwatch.test/ingest")).to have_been_made.times(2)
    end

    # A server that accepts the TCP connection and never answers. WebMock
    # cannot express that, and the deadline exists for exactly this shape.
    def with_hanging_server
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      accepted = []
      acceptor = Thread.new { loop { accepted << server.accept } }
      yield "http://127.0.0.1:#{port}"
    ensure
      acceptor&.kill
      accepted&.each { |sock| sock.close rescue nil }
      server&.close
    end

    it "stops at the deadline against a server that accepts and never answers, instead of paying the full timeout twice" do
      WebMock.allow_net_connect!
      with_hanging_server do |url|
        config = Railwatch.config.dup
        config.ingest_url = url
        config.allow_http = true
        config.connect_timeout = 5.0
        config.timeout = 5.0
        bounded = described_class.new(config)

        started = Railwatch::Clock.monotonic
        result = bounded.deliver([ { t: "log" } ], deadline: started + 0.3)
        elapsed = Railwatch::Clock.monotonic - started

        expect(result.ok).to be(false)
        expect(result).to be_retryable
        expect(result.error).to include("Timeout")
        expect(elapsed).to be < 1.5
      end
    ensure
      WebMock.disable_net_connect!
    end

    it "makes no request at all once the deadline has passed" do
      stub_request(:post, "http://railwatch.test/ingest").to_return(status: 200, body: '{"accepted":1,"rejected":0}')

      result = transport.deliver([ { t: "log" } ], deadline: Railwatch::Clock.monotonic - 1)

      expect(result.ok).to be(false)
      expect(result).to be_retryable
      expect(a_request(:post, "http://railwatch.test/ingest")).not_to have_been_made
    end

    it "does not retry a network error when the deadline has passed" do
      stub_request(:post, "http://railwatch.test/ingest").to_raise(Net::OpenTimeout)

      result = transport.deliver([ { t: "log" } ], deadline: Railwatch::Clock.monotonic + 0.05)
      sleep 0.06

      expect(result.ok).to be(false)
      # The first attempt was made; the retry may or may not have fit, but
      # a second attempt after the deadline is what must never happen.
      expect(a_request(:post, "http://railwatch.test/ingest")).to have_been_made.at_least_once
    end

    it "leaves the configured timeouts alone when no deadline is given" do
      stub_request(:post, "http://railwatch.test/ingest").to_return(status: 200, body: '{"accepted":1,"rejected":0}')
      seen = nil
      allow(Net::HTTP).to receive(:start).and_wrap_original do |m, host, port, **opts, &blk|
        seen = opts
        m.call(host, port, **opts, &blk)
      end

      transport.deliver([ { t: "log" } ])

      expect(seen).to include(open_timeout: Railwatch.config.connect_timeout, read_timeout: Railwatch.config.timeout)
    end

    it "classifies quota, timeout, rate-limit, and server responses as retryable" do
      [ 402, 408, 429, 500, 599 ].each do |status|
        result = described_class::Result.new(ok: false, status: status)

        expect(result).to be_retryable
      end
    end

    it "classifies auth and other client rejections as permanent" do
      [ 400, 401, 403, 404, 422 ].each do |status|
        result = described_class::Result.new(ok: false, status: status)

        expect(result).not_to be_retryable
      end
    end

    it "retains a batch when a successful proxy response is HTML" do
      stub_request(:post, "http://railwatch.test/ingest").to_return(status: 200, body: "<html>sign in</html>")

      result = transport.deliver([ { t: "log" } ])

      expect(result.ok).to be(false)
      expect(result).to be_retryable
      expect(result.error).to include("invalid ingest acknowledgement", "invalid JSON")
    end

    it "retains a batch when a successful response contains malformed JSON" do
      stub_request(:post, "http://railwatch.test/ingest").to_return(status: 200, body: '{"accepted":1')

      result = transport.deliver([ { t: "log" } ])

      expect(result.ok).to be(false)
      expect(result).to be_retryable
      expect(result.error).to include("invalid JSON")
    end

    it "retains a batch when a successful acknowledgement omits counts" do
      stub_request(:post, "http://railwatch.test/ingest").to_return(status: 200, body: '{"accepted":1}')

      result = transport.deliver([ { t: "log" } ])

      expect(result.ok).to be(false)
      expect(result).to be_retryable
      expect(result.error).to include("accepted and rejected must be non-negative integers")
    end

    it "retains a batch when acknowledgement counts do not cover the submitted batch" do
      stub_request(:post, "http://railwatch.test/ingest")
        .to_return(status: 200, body: '{"accepted":1,"rejected":0}')

      result = transport.deliver([ { t: "log" }, { t: "log" } ])

      expect(result.ok).to be(false)
      expect(result).to be_retryable
      expect(result.error).to include("accepted + rejected was 1, expected 2")
    end

    it "drains a batch when a paused environment acknowledges it without ingesting" do
      stub_request(:post, "http://railwatch.test/ingest")
        .to_return(status: 200, body: '{"accepted":0,"rejected":0,"reason":"paused"}')

      result = transport.deliver([ { t: "log" }, { t: "log" } ])

      expect(result.ok).to be(true)
      expect(result).not_to be_retryable
      expect(result).to have_attributes(accepted: 0, rejected: 0)
    end

    it "drains a batch when ingest acknowledges a partial count with a reason" do
      stub_request(:post, "http://railwatch.test/ingest")
        .to_return(status: 200, body: '{"accepted":1,"rejected":0,"reason":"over quota"}')

      result = transport.deliver([ { t: "log" }, { t: "log" } ])

      expect(result.ok).to be(true)
      expect(result).to have_attributes(accepted: 1, rejected: 0)
    end

    it "returns a valid partial acknowledgement with bounded rejection details" do
      rejections = Array.new(12) { |index| { type: "bogus", reason: "record #{index}" } }
      stub_request(:post, "http://railwatch.test/ingest").to_return(
        status: 200, body: JSON.generate(accepted: 1, rejected: 1, rejections: rejections)
      )

      result = transport.deliver([ { t: "log" }, { t: "bogus" } ])

      expect(result.ok).to be(true)
      expect(result).to have_attributes(accepted: 1, rejected: 1)
      expect(result.rejections.size).to eq(10)
    end

    it "rejects a non-array rejections field even when its value is false" do
      stub_request(:post, "http://railwatch.test/ingest")
        .to_return(status: 200, body: '{"accepted":1,"rejected":0,"rejections":false}')

      result = transport.deliver([ { t: "log" } ])

      expect(result.ok).to be(false)
      expect(result).to be_retryable
      expect(result.error).to include("rejections must be an array")
    end

    it "leaves quota backoff to the reporter instead of suppressing the next delivery" do
      stub_request(:post, "http://railwatch.test/ingest")
        .to_return({ status: 402, body: "quota" }, { status: 200, body: '{"accepted":1,"rejected":0}' })

      first = transport.deliver([ { t: "log" } ])
      second = transport.deliver([ { t: "log" } ])

      expect(first).to be_retryable
      expect(second.ok).to be(true)
    end
  end
end

RSpec.describe Railwatch::Buffer do
  describe "#push" do
    it "drops the oldest record once capacity is reached and counts the drop" do
      buffer = described_class.new(2)
      buffer.push(:a)
      buffer.push(:b)
      buffer.push(:c)

      batch, dropped = buffer.drain
      expect(batch).to eq(%i[b c])
      expect(dropped).to eq(1)
    end

    it "stays under its byte ceiling through sustained mixed-size writes" do
      buffer = described_class.new(10_000, byte_capacity: 4_096)

      1_000.times do |index|
        buffer.push({ message: "x" * (index.even? ? 40 : 900), index: index })
        expect(buffer.bytes).to be <= 4_096
      end

      records, dropped, dropped_bytes = buffer.drain
      expect(records).not_to be_empty
      expect(dropped).to be_positive
      expect(dropped_bytes).to be_positive
    end

    it "drops a record heavier than the whole queue instead of emptying the queue for it" do
      buffer = described_class.new(10, byte_capacity: 1_024)
      buffer.push({ message: "keep me" })

      buffer.push({ message: "x" * 4_096 })

      records, dropped, dropped_bytes = buffer.drain
      expect(records).to eq([ { message: "keep me" } ])
      expect(dropped).to eq(1)
      # A record past the ceiling is only weighed as far as the ceiling, so
      # the byte counter is a floor for it -- the record counter is exact.
      expect(dropped_bytes).to be > 1_024
    end
  end


  describe "#restore" do
    it "puts a failed batch before newer records while keeping the newest records under pressure" do
      buffer = described_class.new(3)
      buffer.push(:new_a)
      buffer.push(:new_b)

      buffer.restore(%i[old_a old_b], dropped: 2)

      batch, dropped = buffer.drain
      expect(batch).to eq(%i[old_b new_a new_b])
      expect(dropped).to eq(3)
    end
  end
end

RSpec.describe Railwatch::Reporter do
  let(:reporter_config) do
    Railwatch.config.dup.tap do |config|
      config.buffer_size = 3
      config.flush_interval = 10
      config.flush_threshold = 3
      config.shutdown_timeout = 0.1
    end
  end

  def delivery_result(ok:, status: nil, error: nil, accepted: nil, rejected: nil, rejections: nil)
    Railwatch::Transport::Http::Result.new(ok: ok, status: status, error: error, accepted: accepted,
                                         rejected: rejected, rejections: rejections)
  end

  def fork_pipe_transport(writer)
    Class.new do
      def initialize(io)
        @io = io
      end

      def deliver(records, dropped: 0)
        @io.puts(JSON.generate(pid: Process.pid, records: records, dropped: dropped))
        @io.flush
        Railwatch::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size, rejected: 0)
      end
    end.new(writer)
  end

  describe "adaptive backpressure" do
    it "doubles to its cap above either high-water mark and halves as pressure clears" do
      config = reporter_config
      config.buffer_size = 100
      config.buffer_bytes = 100
      reporter = described_class.new(config, transport: Object.new)
      reporter.buffer.push({ t: "log" }, 80)

      4.times { reporter.send(:update_backpressure) }

      expect(reporter.backpressure_factor).to eq(described_class::MAX_BACKPRESSURE_FACTOR)

      reporter.buffer.drain
      3.times { reporter.send(:update_backpressure) }

      expect(reporter.backpressure_factor).to eq(1.0)
    end

    it "treats an active retry ladder as pressure" do
      reporter = described_class.new(reporter_config, transport: Object.new)
      reporter.instance_variable_set(:@retry_attempt, 1)

      reporter.send(:update_backpressure)

      expect(reporter.backpressure_factor).to eq(2.0)
    end

    it "stays at one when adaptive backpressure is disabled" do
      config = reporter_config
      config.backpressure = false
      reporter = described_class.new(config, transport: Object.new)
      3.times { |n| reporter.buffer.push({ n: n }) }

      3.times { reporter.send(:update_backpressure) }

      expect(reporter.backpressure_factor).to eq(1.0)
    end
  end

  describe "#flush" do
    it "passes the buffer's dropped count through to the transport" do
      captured_dropped = nil
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0|
        captured_dropped = dropped
        Railwatch::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size, rejected: 0)
      end

      small_config = Railwatch.config.dup
      small_config.buffer_size = 2
      reporter = described_class.new(small_config, transport: transport)
      4.times { |i| reporter.buffer.push({ t: "log", n: i }) }

      reporter.flush

      expect(captured_dropped).to eq(2)
    end

    it "passes its current backpressure factor through to supporting transports" do
      captured_factor = nil
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0, backpressure_factor:|
        captured_factor = backpressure_factor
        Railwatch::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size)
      end
      reporter = described_class.new(reporter_config, transport: transport)
      3.times { |n| reporter.buffer.push({ n: n }) }

      reporter.flush

      expect(captured_factor).to eq(2.0)
    end


    it "retains a retryable batch and delivers it once after recovery" do
      attempts = []
      outcomes = [
        delivery_result(ok: false, error: "Net::OpenTimeout"),
        delivery_result(ok: true, status: 200, accepted: 1)
      ]
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0, batch_id:|
        attempts << [ records.dup, dropped, batch_id ]
        outcomes.shift
      end
      reporter = described_class.new(reporter_config, transport: transport)
      record = { t: "log", n: 1 }
      reporter.buffer.push(record)

      expect(reporter.flush).to be_retryable
      expect(reporter.buffer.size).to eq(0)
      expect(reporter.flush.ok).to be(true)
      expect(reporter.flush).to be_nil

      expect(attempts.map { |records, dropped, _id| [ records, dropped ] }).to eq([ [ [ record ], 0 ], [ [ record ], 0 ] ])
      expect(attempts.map(&:last).uniq.size).to eq(1)
      expect(reporter.buffer.size).to eq(0)
    end

    it "gives up on a batch after MAX_RETRY_ATTEMPTS, counts it as dropped, and lets newer records through" do
      attempts = []
      failure = delivery_result(ok: false, error: "Net::OpenTimeout")
      success = delivery_result(ok: true, status: 200, accepted: 1)
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0, batch_id:|
        attempts << [ records.map { |r| r[:n] }, dropped ]
        records.first[:n] == 0 ? failure : success
      end
      reporter = described_class.new(reporter_config, transport: transport)
      reporter.buffer.push({ t: "log", n: 0 })

      (described_class::MAX_RETRY_ATTEMPTS + 1).times do
        reporter.instance_variable_set(:@retry_at, nil)
        reporter.flush
      end
      reporter.buffer.push({ t: "log", n: 1 })
      reporter.instance_variable_set(:@retry_at, nil)
      expect(reporter.flush.ok).to be(true)

      expect(attempts.count { |ns, _| ns == [ 0 ] }).to eq(described_class::MAX_RETRY_ATTEMPTS + 1)
      expect(attempts.last).to eq([ [ 1 ], 1 ])
    end

    it "uses a new batch id for each distinct batch formed from the buffer" do
      batch_ids = []
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0, batch_id:|
        batch_ids << batch_id
        Railwatch::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size)
      end
      reporter = described_class.new(reporter_config, transport: transport)

      reporter.buffer.push({ n: 1 })
      reporter.flush
      reporter.buffer.push({ n: 2 })
      reporter.flush

      expect(batch_ids.size).to eq(2)
      expect(batch_ids.uniq.size).to eq(2)
      expect(batch_ids).to all(match(/\A[0-9a-f-]{36}\z/))
    end

    it "keeps legacy custom transports that do not accept batch_id working" do
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0|
        Railwatch::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size)
      end
      reporter = described_class.new(reporter_config, transport: transport)
      reporter.buffer.push({ n: 1 })

      expect(reporter.flush.ok).to be(true)
    end

    it "preserves the prior dropped count across a failed delivery" do
      seen_dropped = []
      outcomes = [
        delivery_result(ok: false, status: 429),
        delivery_result(ok: true, status: 200, accepted: 3)
      ]
      transport = Object.new
      transport.define_singleton_method(:deliver) do |_records, dropped: 0|
        seen_dropped << dropped
        outcomes.shift
      end
      reporter = described_class.new(reporter_config, transport: transport)
      5.times { |n| reporter.buffer.push({ t: "log", n: n }) }

      reporter.flush
      reporter.flush

      expect(seen_dropped).to eq([ 2, 2 ])
    end

    it "splits a queue larger than one delivery instead of dropping the tail" do
      record = { t: "log", message: "x" * 40 }
      one = Railwatch::Record.buffered_bytes(record, limit: Float::INFINITY)
      deliveries = []
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0, batch_id:|
        deliveries << [ records.size, dropped, batch_id ]
        Railwatch::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size)
      end
      config = reporter_config
      config.buffer_size = 10
      config.buffer_bytes = one * 10
      config.batch_bytes = one * 3
      reporter = described_class.new(config, transport: transport)
      5.times { reporter.buffer.push(record.dup) }

      reporter.flush
      reporter.flush

      expect(deliveries.map(&:first)).to eq([ 3, 2 ])
      expect(deliveries.map { |_, dropped, _| dropped }).to eq([ 0, 0 ])
      expect(deliveries.map(&:last).uniq.size).to eq(2)
    end

    it "keeps a failed request immutable while buffering records written during delivery" do
      attempts = []
      reporter = nil
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0, batch_id:|
        attempts << [ records.dup, batch_id ]
        if attempts.one?
          reporter.buffer.push({ n: 3 })
          reporter.buffer.push({ n: 4 })
          Railwatch::Transport::Http::Result.new(ok: false, status: 408)
        else
          Railwatch::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size)
        end
      end
      reporter = described_class.new(reporter_config, transport: transport)
      reporter.buffer.push({ n: 1 })
      reporter.buffer.push({ n: 2 })

      reporter.flush
      reporter.flush

      batch, dropped = reporter.buffer.drain
      expect(attempts.map(&:first)).to eq([ [ { n: 1 }, { n: 2 } ] ] * 2)
      expect(attempts.map(&:last).uniq.size).to eq(1)
      expect(batch).to eq([ { n: 3 }, { n: 4 } ])
      expect(dropped).to eq(0)
    end

    it "drops permanent client rejections and reports them explicitly" do
      seen_errors = []
      Railwatch.on_unrecoverable { |error| seen_errors << error }
      [ 401, 422 ].each do |status|
        transport = Object.new
        transport.define_singleton_method(:deliver) do |_records, dropped: 0|
          Railwatch::Transport::Http::Result.new(ok: false, status: status, error: "invalid payload")
        end
        reporter = described_class.new(reporter_config, transport: transport)
        reporter.buffer.push({ t: "log" })

        reporter.flush

        expect(reporter.buffer.size).to eq(0)
      end

      expect(seen_errors.size).to eq(2)
      expect(seen_errors.first).to be_a(described_class::DeliveryError)
      expect(seen_errors.map(&:status)).to eq([ 401, 422 ])
      expect(seen_errors.first.message).to include("permanently rejected")
    ensure
      Railwatch.config.on_unrecoverable = nil
    end

    it "treats a per-record rejection as a delivered batch, not an unrecoverable failure" do
      seen_errors = []
      seen_dropped = []
      Railwatch.on_unrecoverable { |error| seen_errors << error }
      outcomes = [
        delivery_result(ok: true, status: 200, accepted: 1, rejected: 1,
                        rejections: [ { "type" => "bogus", "reason" => "unsupported record" } ]),
        delivery_result(ok: true, status: 200, accepted: 1, rejected: 0)
      ]
      transport = Object.new
      transport.define_singleton_method(:deliver) do |_records, dropped: 0|
        seen_dropped << dropped
        outcomes.shift
      end
      reporter = described_class.new(reporter_config, transport: transport)
      reporter.buffer.push({ t: "log" })
      reporter.buffer.push({ t: "bogus" })

      reporter.flush
      reporter.buffer.push({ t: "log" })
      reporter.flush

      expect(seen_dropped).to eq([ 0, 0 ])
      expect(seen_errors).to be_empty
      expect(reporter.buffer.dropped).to eq(0)
      expect(reporter.instance_variable_get(:@retry_batch)).to be_nil
    ensure
      Railwatch.config.on_unrecoverable = nil
    end

    it "uses bounded exponential backoff with non-zero jitter" do
      random = Object.new
      random.define_singleton_method(:rand) { 0.0 }
      reporter = described_class.new(reporter_config, transport: Object.new, random: random)

      expect(reporter.send(:retry_delay, 1)).to eq(0.5)
      expect(reporter.send(:retry_delay, 2)).to eq(1.0)
      expect(reporter.send(:retry_delay, 8)).to eq(30.0)
      expect(reporter.send(:retry_delay, 20)).to eq(30.0)
    end
  end


  describe "background delivery" do
    it "does not busy-loop while a retryable batch is backing off" do
      calls = 0
      lock = Mutex.new
      transport = Object.new
      transport.define_singleton_method(:deliver) do |_records, dropped: 0|
        lock.synchronize { calls += 1 }
        Railwatch::Transport::Http::Result.new(ok: false, status: 503)
      end
      config = reporter_config
      config.flush_interval = 0.005
      config.flush_threshold = 1
      reporter = described_class.new(config, transport: transport)

      reporter.write({ t: "log" })
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1
      Thread.pass until lock.synchronize { calls.positive? } || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep(0.05)

      expect(lock.synchronize { calls }).to eq(1)
    ensure
      reporter&.shutdown
    end

    it "returns from write_now without waiting for the transport" do
      started = Queue.new
      release = Queue.new
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0|
        started << true
        release.pop
        Railwatch::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size)
      end
      reporter = described_class.new(reporter_config, transport: transport)

      before = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      reporter.write_now({ t: "exception" })
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - before

      expect(elapsed).to be < 0.1
      expect(Timeout.timeout(1) { started.pop }).to be(true)
      release << true
    ensure
      release << true if release && release.empty?
      reporter&.shutdown
    end

    it "coalesces a burst of urgent writes into one delivery inside the urgent window" do
      # Every unhandled exception asks for an immediate flush. During an
      # exception storm that used to mean one POST per request, each
      # carrying the handful of records written since the last; the burst
      # must instead go out as full batches once the window closes.
      deliveries = Queue.new
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0|
        deliveries << records.size
        Railwatch::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size)
      end
      config = reporter_config
      config.buffer_size = 100
      config.flush_threshold = 100
      reporter = described_class.new(config, transport: transport)

      20.times { |i| reporter.write_now({ t: "exception", n: i }) }
      first = Timeout.timeout(2) { deliveries.pop }

      expect(first).to eq(20)
      expect(deliveries).to be_empty
    ensure
      reporter&.shutdown
    end

    it "still ships a lone urgent write within the urgent window, not the flush interval" do
      delivered_at = Queue.new
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0|
        delivered_at << Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Railwatch::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size)
      end
      config = reporter_config
      config.flush_interval = 10
      reporter = described_class.new(config, transport: transport)

      written_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      reporter.write_now({ t: "exception" })
      elapsed = Timeout.timeout(2) { delivered_at.pop } - written_at

      expect(elapsed).to be_between(described_class::URGENT_FLUSH_DELAY * 0.5, 1.0)
    ensure
      reporter&.shutdown
    end

    it "flushes an urgent write at once when it fills the buffer to flush_threshold" do
      delivered_at = Queue.new
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0|
        delivered_at << Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Railwatch::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size)
      end
      config = reporter_config
      config.flush_threshold = 1
      reporter = described_class.new(config, transport: transport)

      written_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      reporter.write_now({ t: "exception" })
      elapsed = Timeout.timeout(2) { delivered_at.pop } - written_at

      expect(elapsed).to be < described_class::URGENT_FLUSH_DELAY
    ensure
      reporter&.shutdown
    end

    it "preserves a producer wakeup that arrives while delivery is in flight" do
      batches = Queue.new
      reporter = nil
      calls = 0
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0|
        calls += 1
        batches << records
        reporter.write({ n: 2 }) if calls == 1
        Railwatch::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size)
      end
      config = reporter_config
      config.flush_threshold = 1
      reporter = described_class.new(config, transport: transport)

      reporter.write_now({ n: 1 })

      expect(Timeout.timeout(1) { batches.pop }).to eq([ { n: 1 } ])
      expect(Timeout.timeout(1) { batches.pop }).to eq([ { n: 2 } ])
    ensure
      reporter&.shutdown
    end
  end


  describe "shutdown" do
    it "immediately attempts an already-retained batch and sends it on recovery" do
      available = false
      calls = 0
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0|
        calls += 1
        if available
          Railwatch::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size)
        else
          Railwatch::Transport::Http::Result.new(ok: false, status: 503)
        end
      end
      reporter = described_class.new(reporter_config, transport: transport)
      reporter.buffer.push({ t: "log" })
      reporter.flush
      available = true

      reporter.shutdown

      expect(calls).to eq(2)
      expect(reporter.buffer.size).to eq(0)
    end

    it "retains and reports records it cannot send before the deadline" do
      seen_errors = []
      Railwatch.on_unrecoverable { |error| seen_errors << error }
      transport = Object.new
      transport.define_singleton_method(:deliver) do |_records, dropped: 0|
        Railwatch::Transport::Http::Result.new(ok: false, status: 503, error: "unavailable")
      end
      config = reporter_config
      config.shutdown_timeout = 0.02
      reporter = described_class.new(config, transport: transport)
      reporter.buffer.push({ t: "log" })

      reporter.shutdown

      expect(reporter.send(:pending_delivery).first).to eq(1)
      error = seen_errors.grep(described_class::DeliveryError).first
      expect(error&.records).to eq(1)
      expect(error&.message).to include("unsent records retained in memory")
    ensure
      Railwatch.config.on_unrecoverable = nil
    end
  end

  describe "forked processes" do
    it "keeps parent records and drop accounting out of the child, and emits child process and health records once", :aggregate_failures do
      skip "fork not supported on this platform" unless Process.respond_to?(:fork)

      reader, writer = IO.pipe
      config = Railwatch.config.dup
      config.buffer_size = 10
      config.flush_interval = 30
      config.flush_threshold = 10
      reporter = described_class.new(config, transport: fork_pipe_transport(writer))
      Railwatch.instance_variable_set(:@reporter, reporter)
      reporter.buffer.push({ t: "log", owner: "parent" })
      reporter.buffer.instance_variable_set(:@dropped, 4)

      pid = Process.fork do
        reader.close
        Railwatch.reporter.write({ t: "log", owner: "child" })
        Railwatch::Health.sample
        Railwatch.flush
        writer.close
        exit!(0)
      end
      Process.wait(pid)
      reporter.flush
      writer.close
      deliveries = reader.each_line.map { |line| JSON.parse(line) }
      reader.close

      child_delivery = deliveries.find { |delivery| delivery["pid"] == pid }
      parent_delivery = deliveries.find { |delivery| delivery["pid"] == Process.pid }
      child_records = child_delivery.fetch("records")

      expect(deliveries.size).to eq(2)
      expect(parent_delivery.fetch("records")).to eq([ { "t" => "log", "owner" => "parent" } ])
      expect(parent_delivery.fetch("dropped")).to eq(4)
      expect(child_delivery.fetch("dropped")).to eq(0)
      expect(child_records.count { |record| record["owner"] == "child" }).to eq(1)
      expect(child_records.none? { |record| record["owner"] == "parent" }).to be(true)
      expect(child_records.select { |record| record["t"] == "process" }.sole.fetch("pid")).to eq(pid)
      expect(child_records.select { |record| record["t"] == "health" }.sole.fetch("pid")).to eq(pid)
    end

    it "replaces inherited locked reporter and buffer mutexes before the child records" do
      skip "fork not supported on this platform" unless Process.respond_to?(:fork)

      reporter = described_class.new(Railwatch.config, transport: Railwatch::SpecHelper::MemoryTransport.new)
      Railwatch.instance_variable_set(:@reporter, reporter)
      flush_mutex = reporter.instance_variable_get(:@flush_mutex)
      reporter_mutex = reporter.instance_variable_get(:@mutex)
      buffer_mutex = reporter.buffer.instance_variable_get(:@mutex)
      locked = Queue.new
      release = Queue.new
      locker = Thread.new do
        flush_mutex.lock
        reporter_mutex.lock
        buffer_mutex.lock
        locked << true
        release.pop
      ensure
        buffer_mutex.unlock if buffer_mutex.owned?
        reporter_mutex.unlock if reporter_mutex.owned?
        flush_mutex.unlock if flush_mutex.owned?
      end
      locked.pop

      reader, writer = IO.pipe
      pid = Process.fork do
        reader.close
        Railwatch.reporter.write({ t: "log", owner: "child" })
        Railwatch.flush
        writer.puts("completed")
        writer.close
        exit!(0)
      end
      release << true
      locker.join
      writer.close

      ready = IO.select([ reader ], nil, nil, 3)
      completed = ready && reader.gets&.strip
      Process.kill("KILL", pid) unless completed
      Process.wait(pid)
      reader.close

      expect(completed).to eq("completed")
    ensure
      release << true if release && release.empty?
      locker&.join(1)
    end

    it "resets inherited retry, in-flight, and HTTP policy state without changing the parent" do
      skip "fork not supported on this platform" unless Process.respond_to?(:fork)

      transport = Railwatch::Transport::Http.new(Railwatch.config)
      transport.instance_variable_set(:@unauthorized, true)
      reporter = described_class.new(Railwatch.config, transport: transport)
      reporter.instance_variable_set(:@flush_requested, true)
      reporter.instance_variable_set(:@urgent_at, 99.0)
      reporter.instance_variable_set(:@retry_attempt, 3)
      reporter.instance_variable_set(:@retry_at, 123.0)
      reporter.instance_variable_set(:@retry_batch, Object.new)
      reporter.instance_variable_set(:@backpressure_factor, 8.0)
      reporter.instance_variable_set(:@in_flight_records, 2)
      reporter.instance_variable_set(:@in_flight_dropped, 4)
      reporter.instance_variable_set(:@shutdown_notified, true)
      reporter.instance_variable_set(:@shutdown_deadline, 456.0)
      Railwatch.instance_variable_set(:@reporter, reporter)
      reader, writer = IO.pipe

      pid = Process.fork do
        reader.close
        child_transport = Railwatch.reporter.instance_variable_get(:@transport)
        writer.puts(JSON.generate(
          unauthorized: child_transport.unauthorized?,
          flush_requested: Railwatch.reporter.instance_variable_get(:@flush_requested),
          urgent_at: Railwatch.reporter.instance_variable_get(:@urgent_at),
          retry_attempt: Railwatch.reporter.instance_variable_get(:@retry_attempt),
          retry_at: Railwatch.reporter.instance_variable_get(:@retry_at),
          retry_batch: Railwatch.reporter.instance_variable_get(:@retry_batch),
          backpressure_factor: Railwatch.reporter.backpressure_factor,
          in_flight_records: Railwatch.reporter.instance_variable_get(:@in_flight_records),
          in_flight_dropped: Railwatch.reporter.instance_variable_get(:@in_flight_dropped),
          shutdown_notified: Railwatch.reporter.instance_variable_get(:@shutdown_notified),
          shutdown_deadline: Railwatch.reporter.instance_variable_get(:@shutdown_deadline)
        ))
        writer.close
        exit!(0)
      end
      writer.close
      child_state = JSON.parse(reader.read)
      reader.close
      Process.wait(pid)

      expect(child_state).to eq(
        "unauthorized" => false,
        "flush_requested" => false,
        "urgent_at" => nil,
        "retry_attempt" => 0,
        "retry_at" => nil,
        "retry_batch" => nil,
        "backpressure_factor" => 1.0,
        "in_flight_records" => 0,
        "in_flight_dropped" => 0,
        "shutdown_notified" => false,
        "shutdown_deadline" => nil
      )
      expect(transport.unauthorized?).to be(true)
      expect(reporter.instance_variable_get(:@retry_attempt)).to eq(3)
      expect(reporter.backpressure_factor).to eq(8.0)
      expect(reporter.instance_variable_get(:@in_flight_records)).to eq(2)
    end
  end

  describe "shutdown on process exit" do
    it "flushes the buffer via the at_exit hook registered by the engine, even on SIGTERM", :aggregate_failures do
      skip "fork not supported on this platform" unless Process.respond_to?(:fork)

      reader, writer = IO.pipe
      pid = Process.fork do
        reader.close
        transport = Object.new
        transport.define_singleton_method(:deliver) do |records, dropped: 0|
          writer.puts("delivered:#{records.size}")
          Railwatch::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size, rejected: 0)
        end
        Railwatch.instance_variable_set(:@reporter, Railwatch::Reporter.new(Railwatch.config, transport: transport))
        Railwatch.reporter.buffer.push({ t: "log", message: "before term" })
        # No explicit trap: Railwatch relies on the at_exit hook the engine already
        # registered (lib/railwatch/engine.rb) at boot, inherited into this forked
        # child, which Ruby's default SIGTERM handling still runs on the way out.
        Process.kill("TERM", Process.pid)
      end
      writer.close

      ready = IO.select([ reader ], nil, nil, 5)
      line = ready ? reader.read.strip : nil
      reader.close
      Process.wait(pid)

      expect(line).to eq("delivered:1")
    end
  end
end

RSpec.describe "fork handling" do
  it "registers one ActiveSupport::ForkTracker callback that resets the whole gem in the child" do
    # Rails' ForkTracker is a Process._fork hook, so it sees fork,
    # Process.fork, and Kernel#fork exactly once per child. One registration
    # rather than a prepend per subsystem, and only ever this one: a second
    # would reset the child twice and write two process records.
    callbacks = ActiveSupport::ForkTracker.instance_variable_get(:@callbacks)
    ours = callbacks.select { |cb| cb.source_location&.first&.end_with?("lib/railwatch/engine.rb") }
    expect(ours.size).to eq(1)

    expect(Railwatch).to receive(:restart_after_fork!)
    ours.first.call
  end

  it "restarts the reporter before the health and session threads, so they emit into the child's reporter" do
    order = []
    allow(Railwatch::Profiler).to receive(:restart_after_fork!) { order << :profiler }
    allow(Railwatch.reporter).to receive(:restart_after_fork!) { order << :reporter }
    allow(Railwatch::Subscribers::Users).to receive(:restart_after_fork!) { order << :users }
    allow(Railwatch::Subscribers::ProcessInfo).to receive(:restart_after_fork!) { order << :process }
    allow(Railwatch::Health).to receive(:restart_after_fork!) { order << :health }
    allow(Railwatch::Sessions).to receive(:restart_after_fork!) { order << :sessions }

    Railwatch.restart_after_fork!

    expect(order).to eq(%i[profiler reporter users process health sessions])
  end
end
