# frozen_string_literal: true

require "spec_helper"

# The writer process and the socket transport that feeds it. The writer's
# accept loop is driven on a thread here against a temp socket; the process
# lifecycle (fork, parent watch, signals) is the Puma plugin's and is
# exercised on a real host, not in the suite.
RSpec.describe Railwatch::Writer, type: :request do
  around do |example|
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = :http
  end

  let(:environment) { Railwatch::Environment.current }
  let(:socket_path) { File.join(Dir.mktmpdir("rw-writer"), "w.sock") }
  let(:transport) { Railwatch::Transport::Socket.new(Railwatch.config, path: socket_path) }

  def telemetry(&) = environment.with_telemetry(&)

  # A real UNIXServer on the temp path, accepting on a thread and handing
  # each connection to Writer.handle, exactly as Writer#serve does.
  def with_writer
    server = UNIXServer.new(socket_path)
    thread = Thread.new do
      loop do
        sock = begin
          server.accept
        rescue IOError, Errno::EBADF
          break
        end
        described_class.handle(sock)
      end
    end
    yield
  ensure
    server&.close
    thread&.join(2)
  end

  def records_for(path)
    get path
    railwatch_records
  end

  describe "delivering through the socket" do
    it "writes the batch in the writer and answers with the ledger's counts, exactly once per batch id" do
      records = records_for("/widgets")
      id = SecureRandom.uuid

      with_writer do
        first = transport.deliver(records, batch_id: id)
        replay = transport.deliver(records, batch_id: id)

        expect(first.ok).to be(true)
        expect(first.accepted).to eq(records.size)
        expect(replay.accepted).to eq(first.accepted)
      end

      expect(telemetry { Railwatch::Telemetry::IngestBatch.where(batch_id: id).count }).to eq(1)
      expect(telemetry { Railwatch::Telemetry::Execution.where(kind: "request").count }).to eq(1)
    end

    it "groups exceptions into issues inside the writer, so the worker never touches the railwatch database" do
      records = records_for("/boom")

      with_writer { expect(transport.deliver(records, batch_id: SecureRandom.uuid).ok).to be(true) }

      expect(Railwatch::Issue.sole.title).to eq("ArgumentError: kaboom")
      expect(enqueued_jobs).to be_empty
    end

    it "answers a failed write with a retryable error and no exception record of its own" do
      records = records_for("/widgets")
      allow(Railwatch::Ingest::Writer).to receive(:new).and_raise(ActiveRecord::StatementInvalid, "database is locked")

      with_writer do
        result = transport.deliver(records, batch_id: SecureRandom.uuid)
        expect(result.ok).to be(false)
        expect(result.retryable?).to be(true)
        expect(result.error).to include("database is locked")
      end
      expect(railwatch_records(:exception)).to be_empty
    end
  end

  describe "when nothing is listening" do
    it "retries while the socket file exists but refuses, and never falls back" do
      File.write(socket_path, "") # a stale socket file: ECONNREFUSED / ENOTSOCK, not ENOENT
      records = records_for("/widgets")

      results = 5.times.map { transport.deliver(records, batch_id: SecureRandom.uuid) }

      expect(results.map(&:ok)).to all(be(false))
      expect(results.map(&:retryable?)).to all(be(true))
      expect(transport.fallback?).to be(false)
      expect(telemetry { Railwatch::Telemetry::Execution.count }).to eq(0)
    end

    it "falls back to writing in-process after three misses when there is no socket file at all" do
      records = records_for("/widgets")

      first, second = 2.times.map { transport.deliver(records, batch_id: SecureRandom.uuid) }
      expect([ first.ok, second.ok ]).to eq([ false, false ])
      expect(transport.fallback?).to be(false)

      third = transport.deliver(records, batch_id: SecureRandom.uuid)

      expect(third.ok).to be(true)
      expect(transport.fallback?).to be(true)
      expect(telemetry { Railwatch::Telemetry::Execution.where(kind: "request").count }).to eq(1)
    end
  end

  describe "the wedge guard" do
    # The in-flight table is process state; other examples in this file drive
    # Writer.handle on a thread, so start each example from an empty table.
    before { described_class.instance_variable_get(:@in_flight).clear }

    it "sees a write that is still running, and nothing once it has finished" do
      gate = Queue.new
      thread = Thread.new { described_class.track_in_flight("b1") { gate.pop } }
      sleep 0.01 until described_class.oldest_in_flight

      expect(described_class.oldest_in_flight).to be >= 0
      gate << :go
      thread.join(1)
      expect(described_class.oldest_in_flight).to be_nil
    end

    it "exits the process once a write has run past WEDGE_TIMEOUT so Puma respawns a fresh writer" do
      stub_const("Railwatch::Writer::WEDGE_TIMEOUT", 0)
      stub_const("Railwatch::Writer::PARENT_POLL", 0.01)
      exits = Queue.new
      allow(described_class).to receive(:exit!) { |code| exits << code; Thread.current.kill }
      allow(Railwatch).to receive(:notify_unrecoverable)

      gate = Queue.new
      writing = Thread.new { described_class.track_in_flight("stuck") { gate.pop } }
      sleep 0.01 until described_class.oldest_in_flight
      watcher = described_class.watch_wedge
      code = Timeout.timeout(2) { exits.pop }
      watcher.join(1)
      gate << :go
      writing.join(1)

      expect(code).to eq(75)
      expect(Railwatch).to have_received(:notify_unrecoverable).with(an_instance_of(Railwatch::Writer::WedgedError))
    end
  end

  describe ".fork_writer!" do
    it "makes the child the writer before ForkTracker's reset runs, and restores the parent" do
      seen = nil
      allow(described_class).to receive(:fork) do |&block|
        seen = { running_in_child: described_class.running?, role: Railwatch::Subscribers::ProcessInfo.role }
        4242
      end

      pid = described_class.fork_writer! { :never_called_here }

      expect(pid).to eq(4242)
      expect(seen).to eq(running_in_child: true, role: "writer")
      expect(described_class.running?).to be(false)
    end
  end

  describe "transport selection" do
    it "hands a Puma worker the socket transport and the writer itself the SQLite one" do
      expect(Railwatch.local_transport).to be_a(Railwatch::Transport::Socket)

      allow(described_class).to receive(:running?).and_return(true)
      expect(Railwatch.local_transport).to be_a(Railwatch::Transport::Local)
      expect(Railwatch::Subscribers::ProcessInfo.role).to eq("writer")
    end

    it "writes in-process from the first batch when the socket path is longer than the kernel allows" do
      long = File.join(Dir.mktmpdir("rw-writer"), "x" * 120, "w.sock")
      transport = Railwatch::Transport::Socket.new(Railwatch.config, path: long)
      records = records_for("/widgets")

      expect(transport.fallback?).to be(true)
      expect(described_class.listening?(long)).to be(false)
      expect(transport.deliver(records, batch_id: SecureRandom.uuid).ok).to be(true)
      expect(telemetry { Railwatch::Telemetry::Execution.where(kind: "request").count }).to eq(1)
    end

    it "uses the SQLite transport when the socket is configured off" do
      Railwatch.config.writer_socket = nil
      expect(Railwatch.local_transport).to be_a(Railwatch::Transport::Local)
    ensure
      Railwatch.config.writer_socket = "tmp/sockets/railwatch-writer.sock"
    end
  end
end
