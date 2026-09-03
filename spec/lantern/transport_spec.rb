# frozen_string_literal: true

require "spec_helper"

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

    it "retries once on a network error, then gives up without raising and calls on_unrecoverable exactly once" do
      seen_errors = []
      Lantern.on_unrecoverable { |e| seen_errors << e }
      stub_request(:post, "http://lantern.test/ingest").to_raise(Net::OpenTimeout)

      result = nil
      expect { result = transport.deliver([ { t: "log" } ]) }.not_to raise_error

      expect(result.ok).to be(false)
      expect(a_request(:post, "http://lantern.test/ingest")).to have_been_made.times(2)
      expect(seen_errors.size).to eq(1)
      expect(seen_errors.first).to be_a(Net::OpenTimeout)
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
end

RSpec.describe Lantern::Reporter do
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
