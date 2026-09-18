# frozen_string_literal: true

require "socket"
require "zlib"
require "json"
require "fileutils"
# The writer runs the maintenance clock. The engine requires it too, but a
# writer forked by the Puma plugin before the app has finished loading must
# not depend on that ordering.
require "railwatch/maintenance"

module Railwatch
  # The embedded install's writer process. Puma workers hand their batches
  # here over a Unix socket (Transport::Socket) and this process, and only
  # this process, maps them, writes the two SQLite files, folds the rollups,
  # groups exceptions, and runs the maintenance clock. Its GVL is its own, so
  # none of that work is ever interleaved with a request.
  #
  # Forked from the Puma master by the gem's Puma plugin (lib/puma/plugin/
  # railwatch.rb), the same shape as Solid Queue's `solid_queue_mode :fork`.
  # It exits when its parent does. It can also be run on its own for a
  # deployment that wants it supervised separately:
  #   bin/rails runner 'Railwatch::Writer.run!'
  module Writer
    THREADS = 2
    MAX_REQUEST_BYTES = 64 << 20
    # Inflated request ceiling: a batch is at most config.batch_bytes of
    # NDJSON plus envelope, so anything past this is not a batch.
    MAX_INFLATED_BYTES = 128 << 20
    # Connections waiting for a writer thread. Past this the accept loop
    # closes new ones outright; the worker sees a reset and retries on its
    # backoff ladder, which is the right pressure to apply.
    MAX_PENDING = 64
    PARENT_POLL = 2
    # How long a shutdown waits for a batch that is still being written.
    SHUTDOWN_DRAIN = 5
    # A batch write that has run this long is not slow, it is stuck: a
    # SQLite lock that never clears, a t-digest on a pathological input, a
    # connection pool that lost a connection. The supervisor cannot tell a
    # wedged writer from a busy one (kill 0 answers for both), so the writer
    # judges itself: past this the process exits and the plugin respawns it.
    # The batch is retained on the worker, retried, and written by the new
    # writer, with the ledger making that safe. Includes the time spent
    # reading the request, so a client that connects and stops sending is a
    # wedge too, not a permanently parked thread.
    WEDGE_TIMEOUT = 60
    # Linux caps a Unix socket path at 108 bytes including the terminator. A
    # path past that cannot be bound or connected to at all, so the plugin
    # refuses to start rather than fail on every batch, and the doctor says
    # which path to set.
    MAX_SOCKET_PATH = 107

    @running = false
    @expected = false
    @server = nil
    @stopping = false
    @in_flight = {}
    @in_flight_mutex = Mutex.new
    @socket_ino = nil

    module_function

    # True in the writer process itself.
    def running? = @running

    # True in every process that should hand batches to a writer: set by the
    # Puma plugin in the master before the workers fork, so they inherit it.
    # A process without it (a runner, a Solid Queue worker) writes its own.
    def expected? = @expected

    def expected!
      @expected = true
    end

    # Forks a child that is the writer from its first instruction. ForkTracker
    # fires Railwatch.restart_after_fork! in the child before the block runs,
    # and that reset chooses threads and transport by process role; setting
    # the role here, before the fork, is what makes the child come up with
    # the writer's set (reporter + Transport::Local + maintenance) rather
    # than a web worker's followed by the writer's. The parent puts the flag
    # back the moment fork returns, or fails.
    def fork_writer!
      @running = true
      fork do
        yield
        exit!(0)
      end
    ensure
      @running = false
    end

    # Whether something is listening at the configured socket right now.
    def listening?(path = Railwatch.config.writer_socket_path)
      return false if path.nil?

      UNIXSocket.new(path).close
      true
    rescue SystemCallError, ArgumentError
      # ArgumentError: the path is over the kernel's sun_path limit (108
      # bytes on Linux), which a deep checkout can hit; see usable_path?.
      false
    end

    def usable_path?(path)
      !path.nil? && path.bytesize <= MAX_SOCKET_PATH
    end

    # Serves until stopped or until `parent` (a pid) is gone. Never returns
    # to a caller that expects the app to keep running; it is the process.
    def run!(parent: nil)
      path = Railwatch.config.writer_socket_path or raise ArgumentError, "Railwatch.config.writer_socket is unset"
      unless usable_path?(path)
        raise ArgumentError, "writer socket path is #{path.bytesize} bytes; Linux allows #{MAX_SOCKET_PATH}. " \
                             "Set RAILWATCH_WRITER_SOCKET to a shorter path (an absolute one under /tmp or /run works)."
      end
      @running = true
      @stopping = false
      $PROGRAM_NAME = "railwatch-writer: #{File.basename(path)}"
      trap_signals
      bind(path)
      Railwatch.debug { "writer listening at #{path} (pid #{Process.pid})" }
      # Under the Puma plugin ForkTracker has already reset and started
      # everything for the writer role; run standalone (bin/rails runner)
      # nothing has, so these are idempotent second calls at worst.
      Railwatch.reporter.ensure_thread
      Maintenance.start!
      watch_parent(parent) if parent
      watch_wedge
      serve
    ensure
      cleanup(path)
    end

    # The socket's directory is created 0700 and the socket itself 0600: the
    # writer accepts records as trusted, so only this user may reach it. A
    # socket file already there is unlinked only when nothing answers on it;
    # a live writer (an old container sharing a volume, a writer of a Puma
    # that has not finished restarting) keeps its socket and this one fails
    # to start, which the plugin retries.
    def bind(path)
      dir = File.dirname(path)
      FileUtils.mkdir_p(dir, mode: 0o700)
      if File.exist?(path)
        raise Errno::EADDRINUSE, "#{path}: another writer is listening" if listening?(path)

        File.unlink(path)
      end
      @server = UNIXServer.new(path)
      File.chmod(0o600, path)
      @socket_ino = File.stat(path).ino
    end

    def stop!
      @stopping = true
      @server&.close
    rescue IOError
      nil
    end

    # Handles one already-accepted connection: read the request, write the
    # batch, reply. Public so a spec can drive it without a real socket. The
    # whole thing, request read included, counts toward the wedge guard.
    def handle(sock)
      track_in_flight do
        request = read_request(sock)
        result = write_batch(request)
        reply = JSON.generate(result.to_h)
        write_with_deadline(sock, [ reply.bytesize ].pack("N") + reply)
      end
    rescue StandardError => e
      Railwatch.debug { "writer request failed: #{e.class}: #{e.message}" }
      reply = JSON.generate(ok: false, error: "#{e.class}: #{e.message}", retryable_error: true)
      begin
        write_with_deadline(sock, [ reply.bytesize ].pack("N") + reply)
      rescue SystemCallError, IOError, Timeout::Error
        nil
      end
    ensure
      sock.close rescue nil
    end

    # Exactly what Transport::Local#write does; the writer is that code
    # running in a process of its own.
    def write_batch(request)
      Rails.application.executor.wrap do
        environment = Environment.current
        batch_id = request["batch_id"]
        if (ledger = environment.with_telemetry { Ingest::Batch.committed(batch_id) })
          next Transport::Local::Result.new(ok: true, status: 200, accepted: ledger.accepted, rejected: ledger.rejected, rejections: [])
        end

        result = Ingest::Batch.new(environment, request["records"], dropped_by_client: request["dropped"].to_i,
                                   backpressure_factor: request["backpressure_factor"], gem_version: Railwatch::VERSION,
                                   embedded: true, batch_id: batch_id).write!
        Transport::Local::Result.new(ok: true, status: 200, accepted: result.accepted, rejected: result.rejected,
                                     rejections: result.rejections.first(10))
      rescue StandardError => e
        Railwatch.debug { "writer batch failed: #{e.class}: #{e.message}" }
        Transport::Local::Result.new(ok: false, error: "#{e.class}: #{e.message}", retryable_error: true)
      end
    end

    def serve
      queue = Thread::SizedQueue.new(MAX_PENDING)
      workers = Array.new(THREADS) do |i|
        Thread.new do
          Thread.current.name = "railwatch-writer-#{i}"
          while (sock = queue.pop)
            handle(sock)
          end
        end
      end
      loop do
        sock = begin
          @server.accept
        rescue IOError, Errno::EBADF, Errno::EINVAL
          break
        end
        # A full queue means both threads are busy and MAX_PENDING more are
        # waiting; refusing here is what turns that into worker backoff
        # instead of an unbounded pile of open descriptors.
        sock.close unless queue.push(sock, true)
      rescue ThreadError
        sock&.close
      end
    ensure
      # Bounded: a batch still running five seconds after the listener closed
      # does not hold the shutdown open. Its transaction rolls back when the
      # process exits and the client retries it by batch id against the next
      # writer, so the batch is not lost -- it is just not finished here.
      THREADS.times { queue&.push(nil) }
      workers&.each { |t| t.join(SHUTDOWN_DRAIN) }
    end

    # Length-prefixed gzip JSON, read under the wedge deadline, inflated in
    # bounded steps so a request that decompresses past MAX_INFLATED_BYTES
    # is refused before it is materialised.
    def read_request(sock)
      deadline = Clock.monotonic + WEDGE_TIMEOUT
      header = read_exactly(sock, 4, deadline)
      length = header.unpack1("N")
      raise IOError, "request too large (#{length} bytes)" if length > MAX_REQUEST_BYTES

      body = read_exactly(sock, length, deadline)
      JSON.parse(inflate_bounded(body))
    end

    def inflate_bounded(body)
      out = +""
      inflater = Zlib::Inflate.new(Zlib::MAX_WBITS + 32)
      body.each_char.each_slice(65_536) do |slice|
        out << inflater.inflate(slice.join)
        raise IOError, "request inflates past #{MAX_INFLATED_BYTES} bytes" if out.bytesize > MAX_INFLATED_BYTES
      end
      out << inflater.finish
      raise IOError, "request inflates past #{MAX_INFLATED_BYTES} bytes" if out.bytesize > MAX_INFLATED_BYTES

      out
    ensure
      inflater&.close
    end

    def read_exactly(sock, count, deadline)
      buffer = +""
      while buffer.bytesize < count
        remaining = deadline - Clock.monotonic
        raise Timeout::Error, "client did not finish sending within #{WEDGE_TIMEOUT}s" if remaining <= 0
        raise IOError, "client closed the connection" unless sock.wait_readable(remaining)

        chunk = sock.read_nonblock(count - buffer.bytesize, exception: false)
        case chunk
        when :wait_readable then next
        when nil then raise IOError, "client closed the connection"
        else buffer << chunk
        end
      end
      buffer
    end

    def write_with_deadline(sock, data, timeout: Railwatch.config.timeout)
      deadline = Clock.monotonic + timeout
      offset = 0
      while offset < data.bytesize
        remaining = deadline - Clock.monotonic
        raise Timeout::Error, "client did not read the reply within #{timeout}s" if remaining <= 0
        raise IOError, "client closed the connection" unless sock.wait_writable(remaining)

        written = sock.write_nonblock(data.byteslice(offset..), exception: false)
        offset += written if written.is_a?(Integer)
      end
    end

    def watch_parent(parent)
      Thread.new do
        Thread.current.name = "railwatch-writer-parent"
        until @stopping
          sleep PARENT_POLL
          next if Process.ppid == parent

          Railwatch.debug { "writer: parent #{parent} is gone, stopping" }
          stop!
        end
      end
    end

    # Keyed by invocation, never by batch id: a worker that timed out and
    # retried the same batch must not be able to overwrite, or delete, the
    # entry of the original invocation still running.
    def track_in_flight
      token = Object.new
      @in_flight_mutex.synchronize { @in_flight[token] = Clock.monotonic }
      yield
    ensure
      @in_flight_mutex.synchronize { @in_flight.delete(token) }
    end

    # The oldest write still running, in seconds, or nil.
    def oldest_in_flight
      @in_flight_mutex.synchronize do
        started = @in_flight.values.min
        started && Clock.monotonic - started
      end
    end

    # Exits the process, with a note, the moment any single write has run
    # past WEDGE_TIMEOUT. Deliberately exit! and not stop!: a stuck write is
    # holding whatever is stuck, and a graceful drain would wait on it.
    def watch_wedge
      Thread.new do
        Thread.current.name = "railwatch-writer-wedge"
        until @stopping
          sleep PARENT_POLL
          age = oldest_in_flight
          next unless age && age > WEDGE_TIMEOUT

          warn "[railwatch] writer: a batch write has run #{age.round}s (limit #{WEDGE_TIMEOUT}s); exiting so Puma restarts the writer"
          Railwatch.notify_unrecoverable(WedgedError.new("writer batch write exceeded #{WEDGE_TIMEOUT}s"))
          exit!(75)
        end
      end
    end

    class WedgedError < StandardError; end

    def trap_signals
      %w[TERM INT].each do |signal|
        trap(signal) { Thread.new { stop! } }
      end
    end

    # Unlinks the socket only if it is still the one this writer bound. A
    # newer writer that took the path over keeps its socket.
    def cleanup(path)
      Maintenance.stop!
      Railwatch.reporter.shutdown
      if path && @socket_ino && File.exist?(path) && File.stat(path).ino == @socket_ino
        File.unlink(path)
      end
      @running = false
    end
  end
end
