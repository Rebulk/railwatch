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

    it "counts a batch's exceptions onto an issue exactly once however many times its follow-ups run" do
      records = records_for("/boom")
      id = SecureRandom.uuid
      with_writer { transport.deliver(records, batch_id: id) }
      ledger = telemetry { Railwatch::Telemetry::IngestBatch.find_by!(batch_id: id) }
      expect(Railwatch::Issue.sole.occurrences).to eq(1)

      # A crash after the count committed but before the outbox was cleared.
      telemetry { ledger.update_columns(followups: { "group_exception_ids" => records.select { |r| r[:t] == "exception" }.size.times.map { |i| i + 1 } }) }
      telemetry { Railwatch::Telemetry::IngestBatch.find_by!(batch_id: id).drain_followups!(environment) }
      Railwatch::Maintenance.tick

      expect(Railwatch::Issue.sole.occurrences).to eq(1)
      expect(Railwatch::FollowupReceipt.where(batch_id: id).count).to eq(1)
    end

    it "commits the batch even when the live-update broadcast cannot load its cable adapter (redis configured, gem absent)" do
      records = records_for("/widgets")
      allow(ActionCable.server).to receive(:broadcast).and_raise(Gem::LoadError, "redis is not part of the bundle")

      with_writer do
        result = transport.deliver(records, batch_id: SecureRandom.uuid)
        expect(result.ok).to be(true)
        expect(result.accepted).to eq(records.size)
      end
      expect(telemetry { Railwatch::Telemetry::Execution.where(kind: "request").count }).to eq(1)
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
    it "retains and retries, for as long as it takes, when a writer is expected (under the Puma plugin)" do
      expecting = Railwatch::Transport::Socket.new(Railwatch.config, path: socket_path, expected: true)
      records = records_for("/widgets")

      absent = expecting.deliver(records, batch_id: SecureRandom.uuid)
      File.write(socket_path, "") # a stale inode: refuses rather than ENOENT
      stale = expecting.deliver(records, batch_id: SecureRandom.uuid)

      expect([ absent.ok, stale.ok ]).to eq([ false, false ])
      expect([ absent.retryable?, stale.retryable? ]).to eq([ true, true ])
      expect(expecting.fallback?).to be(false)
      expect(telemetry { Railwatch::Telemetry::Execution.count }).to eq(0)
    end

    it "writes batches itself rather than dropping them when an expected writer never answers" do
      # A writer that is restarting comes back in seconds. One that can never
      # bind (an unwritable socket directory, a fork that keeps failing) would
      # otherwise retain until the reporter's retry cap and lose the batch.
      stub_const("Railwatch::Transport::Socket::WRITER_GRACE", 0)
      expecting = Railwatch::Transport::Socket.new(Railwatch.config, path: socket_path, expected: true)
      records = records_for("/widgets")

      result = expecting.deliver(records, batch_id: SecureRandom.uuid)

      expect(result.ok).to be(true)
      expect(expecting.fallback?).to be(true)
      expect(telemetry { Railwatch::Telemetry::Execution.where(kind: "request").count }).to eq(1)
    end

    it "writes in-process from the first miss when no writer is expected (a runner, a Solid Queue worker)" do
      alone = Railwatch::Transport::Socket.new(Railwatch.config, path: socket_path, expected: false)
      records = records_for("/widgets")

      result = alone.deliver(records, batch_id: SecureRandom.uuid)

      expect(result.ok).to be(true)
      expect(alone.fallback?).to be(true)
      expect(telemetry { Railwatch::Telemetry::Execution.where(kind: "request").count }).to eq(1)
    end

    it "retains once the plugin marks a writer expected, even on a transport built before it did (rails server boots the app first)" do
      built_early = Railwatch::Transport::Socket.new(Railwatch.config, path: socket_path)
      records = records_for("/widgets")
      expect(Railwatch::Writer.expected?).to be(false)

      Railwatch::Writer.expected!
      result = built_early.deliver(records, batch_id: SecureRandom.uuid)

      expect(result.ok).to be(false)
      expect(result.retryable?).to be(true)
      expect(built_early.fallback?).to be(false)
      expect(telemetry { Railwatch::Telemetry::Execution.count }).to eq(0)
    ensure
      Railwatch::Writer.instance_variable_set(:@expected, false)
    end

    it "takes the work back when a writer turns up later, instead of writing in-process for ever" do
      # A process that missed the writer once (bare `puma`, whose plugin
      # cannot mark one expected before the app loads; a worker forked before
      # the writer bound) must not be stuck on in-process writes for life.
      stub_const("Railwatch::Transport::Socket::FALLBACK_RECHECK", 0)
      alone = Railwatch::Transport::Socket.new(Railwatch.config, path: socket_path, expected: false)
      records = records_for("/widgets")

      expect(alone.deliver(records, batch_id: SecureRandom.uuid).ok).to be(true)
      expect(alone.fallback?).to be(true)
      written_in_process = telemetry { Railwatch::Telemetry::IngestBatch.count }

      with_writer do
        expect(alone.deliver(records, batch_id: SecureRandom.uuid).ok).to be(true)
      end

      expect(alone.fallback?).to be(false)
      expect(telemetry { Railwatch::Telemetry::IngestBatch.count }).to eq(written_in_process + 1)
    end

    it "treats a stale socket inode with no writer behind it as no writer, not as a permanent retry" do
      File.write(socket_path, "")
      alone = Railwatch::Transport::Socket.new(Railwatch.config, path: socket_path, expected: false)
      records = records_for("/widgets")

      expect(alone.deliver(records, batch_id: SecureRandom.uuid).ok).to be(true)
      expect(alone.fallback?).to be(true)
    end
  end

  describe "the socket's own limits" do
    it "gives up on a client that connects and never finishes sending, instead of parking a writer thread" do
      stub_const("Railwatch::Writer::WEDGE_TIMEOUT", 0.2)
      server = UNIXServer.new(socket_path)
      client = UNIXSocket.new(socket_path)
      accepted = server.accept
      client.write([ 100 ].pack("N") + "only a few bytes")

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      described_class.handle(accepted)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(elapsed).to be < 2
      expect(accepted).to be_closed
    ensure
      client&.close
      server&.close
    end

    it "refuses a request that inflates past the ceiling before materialising it" do
      stub_const("Railwatch::Writer::MAX_INFLATED_BYTES", 10_000)
      bomb = Zlib.gzip("0" * 1_000_000)

      expect { described_class.inflate_bounded(bomb) }.to raise_error(IOError, /inflates past/)
    end

    it "refuses new connections once MAX_PENDING are already waiting, so workers back off instead of piling up" do
      stub_const("Railwatch::Writer::MAX_PENDING", 1)
      stub_const("Railwatch::Writer::THREADS", 1)
      described_class.instance_variable_set(:@server, UNIXServer.new(socket_path))
      described_class.instance_variable_set(:@stopping, false)
      gate = Queue.new
      allow(described_class).to receive(:handle) { |sock| gate.pop; sock.close }
      serving = Thread.new { described_class.serve }

      busy = UNIXSocket.new(socket_path)      # taken by the one thread
      sleep 0.05
      waiting = UNIXSocket.new(socket_path)   # fills the queue
      sleep 0.05
      refused = UNIXSocket.new(socket_path)   # closed by the accept loop
      sleep 0.05

      expect(refused.wait_readable(1)).to be_truthy
      expect(refused.read_nonblock(1, exception: false)).to be_nil # EOF: closed by the writer
    ensure
      2.times { gate << :go }
      described_class.instance_variable_get(:@server)&.close
      serving&.join(2)
      [ busy, waiting, refused ].each { |s| s&.close }
    end
  end

  describe "the wedge guard" do
    # The in-flight table is process state; other examples in this file drive
    # Writer.handle on a thread, so start each example from an empty table.
    before { described_class.instance_variable_get(:@in_flight).clear }

    it "sees a write that is still running, and nothing once it has finished" do
      gate = Queue.new
      thread = Thread.new { described_class.track_in_flight { gate.pop } }
      sleep 0.01 until described_class.oldest_in_flight

      expect(described_class.oldest_in_flight).to be >= 0
      gate << :go
      thread.join(1)
      expect(described_class.oldest_in_flight).to be_nil
    end

    it "keeps seeing a wedged write after a retry of the same batch finished" do
      stuck = Queue.new
      quick = Queue.new
      wedged = Thread.new { described_class.track_in_flight { stuck.pop } }
      sleep 0.01 until described_class.oldest_in_flight
      retried = Thread.new { described_class.track_in_flight { quick.pop } }
      sleep 0.02
      quick << :go
      retried.join(1)

      expect(described_class.oldest_in_flight).to be >= 0.02
    ensure
      stuck << :go
      wedged&.join(1)
    end

    it "exits the process once a write has run past WEDGE_TIMEOUT so Puma respawns a fresh writer" do
      stub_const("Railwatch::Writer::WEDGE_TIMEOUT", 0)
      stub_const("Railwatch::Writer::PARENT_POLL", 0.01)
      exits = Queue.new
      allow(described_class).to receive(:exit!) { |code| exits << code; Thread.current.kill }
      allow(Railwatch).to receive(:notify_unrecoverable)

      gate = Queue.new
      writing = Thread.new { described_class.track_in_flight { gate.pop } }
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

  describe ".bind" do
    it "creates a private directory and a private socket, and refuses to take over a live one" do
      dir = File.join(Dir.mktmpdir("rw-bind"), "private")
      path = File.join(dir, "w.sock")

      described_class.bind(path)
      expect(File.stat(dir).mode & 0o777).to eq(0o700)
      expect(File.stat(path).mode & 0o777).to eq(0o600)

      expect { described_class.bind(path) }.to raise_error(Errno::EADDRINUSE)
    ensure
      described_class.instance_variable_get(:@server)&.close
      described_class.instance_variable_set(:@server, nil)
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
    end

    it "restores the parent's flag when fork itself fails" do
      allow(described_class).to receive(:fork).and_raise(Errno::EAGAIN)

      expect { described_class.fork_writer! { nil } }.to raise_error(Errno::EAGAIN)
      expect(described_class.running?).to be(false)
      expect(described_class.running?).to be(false)
    end
  end

  describe "the engine's own databases" do
    # The abstract bases rescue a missing database.yml entry so a
    # cloud-transport app (which has neither) still boots and eager-loads
    # them. What they must never do is fall through to the host's PRIMARY
    # connection: the telemetry tables are unprefixed, so `sessions`,
    # `visits`, `people` and `notifications` would be the application's own.
    it "binds each base to its own database, never to the host's primary" do
      expect(Railwatch::TelemetryRecord.connection_db_config.name).to eq("railwatch_telemetry")
      expect(Railwatch::ApplicationRecord.connection_db_config.name).to eq("railwatch")
      expect(ActiveRecord::Base.connection_db_config.name).to eq("primary")
    end

    it "refuses to answer at all when its database is not configured" do
      # Active Record refuses connects_to on an anonymous class, so the probe
      # is named first; the body is what both engine bases run.
      stub_const("RailwatchUnconfiguredProbe", Class.new(ActiveRecord::Base))
      RailwatchUnconfiguredProbe.class_eval do
        self.abstract_class = true
        begin
          connects_to database: { writing: :railwatch_nope, reading: :railwatch_nope }
        rescue ActiveRecord::AdapterNotSpecified
          def self.connection_pool = raise(Railwatch::DatabaseNotConfigured, "not configured")
        end
      end

      expect { RailwatchUnconfiguredProbe.connection_pool }.to raise_error(Railwatch::DatabaseNotConfigured)
      expect { RailwatchUnconfiguredProbe.count }.to raise_error(Railwatch::DatabaseNotConfigured)
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
