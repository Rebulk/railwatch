# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe Lantern::Transport::Http do
  let(:transport) { described_class.new(Lantern.config) }

  describe "#deliver" do
    it "posts the batch as gzip NDJSON with the bearer token, gem version, and content headers" do
      captured = nil
      stub_request(:post, "http://lantern.test/ingest").to_return do |request|
        captured = request
        { status: 200, body: '{"accepted":2,"rejected":0}' }
      end

      result = transport.deliver([ { t: "log", message: "a" }, { t: "log", message: "b" } ], dropped: 3)

      expect(result.ok).to be(true)
      expect(result.accepted).to eq(2)
      expect(captured.headers["Authorization"]).to eq("Bearer test-token")
      expect(captured.headers["Content-Type"]).to eq("application/x-ndjson")
      expect(captured.headers["Content-Encoding"]).to eq("gzip")
      expect(captured.headers["X-Lantern-Version"]).to eq(Lantern::VERSION)
      expect(captured.headers["X-Lantern-Dropped"]).to eq("3")

      decoded = Zlib::GzipReader.new(StringIO.new(captured.body)).read
      expect(decoded.each_line.map { |l| JSON.parse(l) }).to eq(
        [ { "t" => "log", "message" => "a" }, { "t" => "log", "message" => "b" } ]
      )
    end

    it "omits the X-Lantern-Dropped header when nothing was dropped" do
      captured = nil
      stub_request(:post, "http://lantern.test/ingest").to_return do |request|
        captured = request
        { status: 200, body: '{"accepted":1}' }
      end

      transport.deliver([ { t: "log" } ], dropped: 0)

      expect(captured.headers).not_to have_key("X-Lantern-Dropped")
    end

    it "retries once on a network error, then returns a retryable result without raising" do
      seen_errors = []
      Lantern.on_unrecoverable { |e| seen_errors << e }
      stub_request(:post, "http://lantern.test/ingest").to_raise(Net::OpenTimeout)

      result = nil
      expect { result = transport.deliver([ { t: "log" } ]) }.not_to raise_error

      expect(result.ok).to be(false)
      expect(result).to be_retryable
      expect(a_request(:post, "http://lantern.test/ingest")).to have_been_made.times(2)
      expect(seen_errors).to be_empty
    ensure
      Lantern.config.on_unrecoverable = nil
    end

    it "falls back to the debug log instead of raising when no on_unrecoverable callback is registered" do
      Lantern.config.on_unrecoverable = nil
      stub_request(:post, "http://lantern.test/ingest").to_raise(Net::OpenTimeout)

      result = nil
      expect { result = transport.deliver([ { t: "log" } ]) }.not_to raise_error
      expect(result.ok).to be(false)
      expect(result.error).to include("Net::OpenTimeout")
    end

    it "retries a 5xx response once and succeeds on the retry" do
      stub_request(:post, "http://lantern.test/ingest")
        .to_return({ status: 503, body: "unavailable" }, { status: 200, body: '{"accepted":1}' })

      result = transport.deliver([ { t: "log" } ])

      expect(result.ok).to be(true)
      expect(a_request(:post, "http://lantern.test/ingest")).to have_been_made.times(2)
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

    it "leaves quota backoff to the reporter instead of suppressing the next delivery" do
      stub_request(:post, "http://lantern.test/ingest")
        .to_return({ status: 402, body: "quota" }, { status: 200, body: '{"accepted":1}' })

      first = transport.deliver([ { t: "log" } ])
      second = transport.deliver([ { t: "log" } ])

      expect(first).to be_retryable
      expect(second.ok).to be(true)
    end
  end
end

RSpec.describe Lantern::Buffer do
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

RSpec.describe Lantern::Reporter do
  let(:reporter_config) do
    Lantern.config.dup.tap do |config|
      config.buffer_size = 3
      config.flush_interval = 10
      config.flush_threshold = 3
      config.shutdown_timeout = 0.1
    end
  end

  def delivery_result(ok:, status: nil, error: nil, accepted: nil)
    Lantern::Transport::Http::Result.new(ok: ok, status: status, error: error, accepted: accepted)
  end

  describe "#flush" do
    it "passes the buffer's dropped count through to the transport" do
      captured_dropped = nil
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0|
        captured_dropped = dropped
        Lantern::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size, rejected: 0)
      end

      small_config = Lantern.config.dup
      small_config.buffer_size = 2
      reporter = described_class.new(small_config, transport: transport)
      4.times { |i| reporter.buffer.push({ t: "log", n: i }) }

      reporter.flush

      expect(captured_dropped).to eq(2)
    end


    it "retains a retryable batch and delivers it once after recovery" do
      attempts = []
      outcomes = [
        delivery_result(ok: false, error: "Net::OpenTimeout"),
        delivery_result(ok: true, status: 200, accepted: 1)
      ]
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0|
        attempts << [ records.dup, dropped ]
        outcomes.shift
      end
      reporter = described_class.new(reporter_config, transport: transport)
      record = { t: "log", n: 1 }
      reporter.buffer.push(record)

      expect(reporter.flush).to be_retryable
      expect(reporter.buffer.size).to eq(1)
      expect(reporter.flush.ok).to be(true)
      expect(reporter.flush).to be_nil

      expect(attempts).to eq([ [ [ record ], 0 ], [ [ record ], 0 ] ])
      expect(reporter.buffer.size).to eq(0)
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

    it "merges records written during delivery and counts oldest losses" do
      reporter = nil
      transport = Object.new
      transport.define_singleton_method(:deliver) do |_records, dropped: 0|
        reporter.buffer.push({ n: 3 })
        reporter.buffer.push({ n: 4 })
        Lantern::Transport::Http::Result.new(ok: false, status: 408)
      end
      reporter = described_class.new(reporter_config, transport: transport)
      reporter.buffer.push({ n: 1 })
      reporter.buffer.push({ n: 2 })

      reporter.flush

      batch, dropped = reporter.buffer.drain
      expect(batch).to eq([ { n: 2 }, { n: 3 }, { n: 4 } ])
      expect(dropped).to eq(1)
    end

    it "drops permanent client rejections and reports them explicitly" do
      seen_errors = []
      Lantern.on_unrecoverable { |error| seen_errors << error }
      [ 401, 422 ].each do |status|
        transport = Object.new
        transport.define_singleton_method(:deliver) do |_records, dropped: 0|
          Lantern::Transport::Http::Result.new(ok: false, status: status, error: "invalid payload")
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
      Lantern.config.on_unrecoverable = nil
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
        Lantern::Transport::Http::Result.new(ok: false, status: 503)
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
        Lantern::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size)
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

    it "preserves a producer wakeup that arrives while delivery is in flight" do
      batches = Queue.new
      reporter = nil
      calls = 0
      transport = Object.new
      transport.define_singleton_method(:deliver) do |records, dropped: 0|
        calls += 1
        batches << records
        reporter.write({ n: 2 }) if calls == 1
        Lantern::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size)
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
          Lantern::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size)
        else
          Lantern::Transport::Http::Result.new(ok: false, status: 503)
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
      Lantern.on_unrecoverable { |error| seen_errors << error }
      transport = Object.new
      transport.define_singleton_method(:deliver) do |_records, dropped: 0|
        Lantern::Transport::Http::Result.new(ok: false, status: 503, error: "unavailable")
      end
      config = reporter_config
      config.shutdown_timeout = 0.02
      reporter = described_class.new(config, transport: transport)
      reporter.buffer.push({ t: "log" })

      reporter.shutdown

      expect(reporter.buffer.size).to eq(1)
      error = seen_errors.grep(described_class::DeliveryError).first
      expect(error&.records).to eq(1)
      expect(error&.message).to include("unsent records retained in memory")
    ensure
      Lantern.config.on_unrecoverable = nil
    end
  end

  describe "forked processes" do
    it "re-arms the reporter thread after fork instead of reusing the parent's dead thread", :aggregate_failures do
      skip "fork not supported on this platform" unless Process.respond_to?(:fork)

      Lantern.reporter.write({ t: "log", message: "parent" })

      reader, writer = IO.pipe
      pid = Process.fork do
        reader.close
        Lantern.reporter.write({ t: "log", message: "child" })
        alive = Lantern.reporter.instance_variable_get(:@thread)&.alive?
        recorded_pid = Lantern.reporter.instance_variable_get(:@pid)
        writer.puts("#{alive}|#{recorded_pid == Process.pid}")
        writer.close
        exit!(0)
      end
      writer.close
      Process.wait(pid)
      alive, pid_matches_child = reader.read.strip.split("|")
      reader.close

      expect(alive).to eq("true")
      expect(pid_matches_child).to eq("true")
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
          Lantern::Transport::Http::Result.new(ok: true, status: 200, accepted: records.size, rejected: 0)
        end
        Lantern.instance_variable_set(:@reporter, Lantern::Reporter.new(Lantern.config, transport: transport))
        Lantern.reporter.buffer.push({ t: "log", message: "before term" })
        # No explicit trap: Lantern relies on the at_exit hook the engine already
        # registered (lib/lantern/engine.rb) at boot, inherited into this forked
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
