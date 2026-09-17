# frozen_string_literal: true

require "socket"
require "zlib"
require "json"

module Railwatch
  module Transport
    # Hands each batch to the embedded writer process (Railwatch::Writer) over
    # a Unix socket instead of writing it into SQLite on this thread. The
    # workers' Ruby threads then never map a record, hold SQLite's write lock,
    # or run a t-digest; all of that happens in one process whose GVL no
    # request shares. Same Reporter, same buffer, same batch id, same ledger:
    # a batch the writer already committed replays as a no-op there.
    #
    # One request per connection, length-prefixed, gzip JSON both ways:
    #   > [u32 length][gzip(JSON {batch_id, records, dropped, dropped_bytes, backpressure_factor})]
    #   < [u32 length][JSON {ok, status, accepted, rejected, rejections, error, retryable_error}]
    #
    # Whether a writer is EXPECTED decides what a missing one means. Under
    # the Puma plugin (which sets Writer.expected! in the master before it
    # forks the workers) a socket that is absent or refusing is a writer
    # that is starting or restarting: the batch is retained and retried on
    # the reporter's backoff ladder, however long that takes. Anywhere else
    # (a plain `rails server`, a runner, a Solid Queue worker, the suite) no
    # writer will ever appear, so the first miss switches this transport to
    # an in-process Transport::Local for the rest of the process's life and
    # embedded mode works exactly as it did before the writer existed. A
    # refusing socket in that case is a stale inode from a dead writer and
    # falls back the same way rather than dropping batches forever.
    class Socket
      Result = Local::Result
      MAX_REPLY_BYTES = 1 << 20

      def initialize(config, path: nil, expected: nil)
        @config = config
        @path = path || config.writer_socket_path
        @expected = expected.nil? ? Writer.expected? : expected
        # A path the kernel cannot bind (over 108 bytes on Linux) can never
        # have a writer behind it; do not spend a batch finding out.
        @fallback = Writer.usable_path?(@path) ? nil : Local.new(config)
        Railwatch.debug { "writer socket path #{@path.inspect} is too long; writing batches in-process" } if @fallback
      end

      attr_reader :path

      def fallback? = !@fallback.nil?

      def deliver(records, dropped: 0, dropped_bytes: 0, backpressure_factor: 1.0, batch_id: nil)
        return @fallback.deliver(records, dropped: dropped, dropped_bytes: dropped_bytes,
                                 backpressure_factor: backpressure_factor, batch_id: batch_id) if @fallback

        payload = Zlib.gzip(JSON.generate(batch_id: batch_id, records: records, dropped: dropped,
                                          dropped_bytes: dropped_bytes, backpressure_factor: backpressure_factor))
        reply = exchange(payload)
        Result.new(**reply.slice("ok", "status", "accepted", "rejected", "rejections", "error", "retryable_error").transform_keys(&:to_sym))
      rescue Errno::ENOENT, Errno::ECONNREFUSED, Errno::ENOTSOCK => e
        if @expected
          Railwatch.debug { "writer not answering at #{@path} (#{e.class}); retaining the batch" }
          return Result.new(ok: false, error: "writer unavailable: #{e.message}", retryable_error: true)
        end

        Railwatch.debug { "no writer at #{@path} (#{e.class}) and none expected; writing batches in-process from now on" }
        @fallback = Local.new(@config)
        deliver(records, dropped: dropped, dropped_bytes: dropped_bytes, backpressure_factor: backpressure_factor, batch_id: batch_id)
      rescue SystemCallError, IOError, Zlib::Error, JSON::ParserError, Timeout::Error => e
        Railwatch.debug { "writer delivery failed: #{e.class}: #{e.message}" }
        Result.new(ok: false, error: "#{e.class}: #{e.message}", retryable_error: true)
      end

      def ping
        return true if @fallback

        UNIXSocket.new(@path).close
        true
      rescue SystemCallError, ArgumentError
        false
      end

      def unauthorized? = false
      def reset_after_fork! = self

      private

      # Every read and write is under one deadline of config.timeout, the
      # same budget the HTTP transport gives a POST; a writer that accepts but
      # stops reading cannot hold the reporter thread past it.
      def exchange(payload)
        UNIXSocket.open(@path) do |sock|
          deadline = Clock.monotonic + @config.timeout
          write_exactly(sock, [ payload.bytesize ].pack("N") + payload, deadline)
          header = read_exactly(sock, 4, deadline)
          length = header.unpack1("N")
          raise IOError, "writer reply too large (#{length} bytes)" if length > MAX_REPLY_BYTES

          JSON.parse(read_exactly(sock, length, deadline))
        end
      end

      def write_exactly(sock, data, deadline)
        offset = 0
        while offset < data.bytesize
          remaining = deadline - Clock.monotonic
          raise Timeout::Error, "writer did not accept the batch within #{@config.timeout}s" if remaining <= 0
          raise IOError, "writer closed the connection" unless sock.wait_writable(remaining)

          written = sock.write_nonblock(data.byteslice(offset..), exception: false)
          offset += written if written.is_a?(Integer)
        end
      end

      def read_exactly(sock, count, deadline)
        buffer = +""
        while buffer.bytesize < count
          remaining = deadline - Clock.monotonic
          raise Timeout::Error, "writer did not answer within #{@config.timeout}s" if remaining <= 0
          raise IOError, "writer closed the connection" unless sock.wait_readable(remaining)

          chunk = sock.read_nonblock(count - buffer.bytesize, exception: false)
          case chunk
          when :wait_readable then next
          when nil then raise IOError, "writer closed the connection"
          else buffer << chunk
          end
        end
        buffer
      end
    end
  end
end
