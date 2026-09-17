# frozen_string_literal: true

require "socket"
require "zlib"
require "json"

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
    PARENT_POLL = 2

    @running = false
    @server = nil
    @stopping = false

    module_function

    # True in the writer process itself.
    def running? = @running

    # Forks a child that is the writer from its first instruction. ForkTracker
    # fires Railwatch.restart_after_fork! in the child before the block runs,
    # and that reset chooses threads and transport by process role; setting
    # the role here, before the fork, is what makes the child come up with
    # the writer's set (reporter + Transport::Local + maintenance) rather
    # than a web worker's followed by the writer's. The parent puts the flag
    # back the moment fork returns.
    def fork_writer!
      @running = true
      pid = fork do
        yield
        exit!(0)
      end
      @running = false
      pid
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

    # Linux caps a Unix socket path at 108 bytes including the terminator. A
    # path past that cannot be bound or connected to at all, so the plugin
    # refuses to start rather than fail on every batch, and the doctor says
    # which path to set.
    MAX_SOCKET_PATH = 107

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
      FileUtils.mkdir_p(File.dirname(path))
      File.unlink(path) if File.exist?(path)
      @server = UNIXServer.new(path)
      Railwatch.debug { "writer listening at #{path} (pid #{Process.pid})" }
      # Under the Puma plugin ForkTracker has already reset and started
      # everything for the writer role; run standalone (bin/rails runner)
      # nothing has, so these are idempotent second calls at worst.
      Railwatch.reporter.ensure_thread
      Maintenance.start!
      watch_parent(parent) if parent
      serve
    ensure
      cleanup(path)
    end

    def stop!
      @stopping = true
      @server&.close
    rescue IOError
      nil
    end

    # Handles one already-accepted connection: read the request, write the
    # batch, reply. Public so a spec can drive it without a real socket.
    def handle(sock)
      request = read_request(sock)
      result = write_batch(request)
      reply = JSON.generate(result.to_h)
      sock.write([ reply.bytesize ].pack("N"), reply)
    rescue StandardError => e
      Railwatch.debug { "writer request failed: #{e.class}: #{e.message}" }
      reply = JSON.generate(ok: false, error: "#{e.class}: #{e.message}", retryable_error: true)
      begin
        sock.write([ reply.bytesize ].pack("N"), reply)
      rescue SystemCallError, IOError
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
      queue = Thread::Queue.new
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
        queue << sock
      end
    ensure
      THREADS.times { queue&.push(nil) }
      workers&.each { |t| t.join(5) }
    end

    def read_request(sock)
      header = sock.read(4) or raise IOError, "empty request"
      length = header.unpack1("N")
      raise IOError, "request too large (#{length} bytes)" if length > MAX_REQUEST_BYTES

      body = sock.read(length)
      raise IOError, "short request" if body.nil? || body.bytesize != length

      JSON.parse(Zlib.gunzip(body))
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

    def trap_signals
      %w[TERM INT].each do |signal|
        trap(signal) { Thread.new { stop! } }
      end
    end

    def cleanup(path)
      Maintenance.stop!
      Railwatch.reporter.shutdown
      File.unlink(path) if path && File.exist?(path)
      @running = false
    end
  end
end
