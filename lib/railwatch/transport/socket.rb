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
    # When there is no writer at all (a plain `rails server`, a runner, a
    # Solid Queue worker, the test suite) the socket file never appears; after
    # FALLBACK_AFTER consecutive misses this delegates to an in-process
    # Transport::Local for the rest of the process's life, so embedded mode
    # works exactly as it did before the writer existed. A socket file that
    # is present but refuses (the writer restarting) is never a fallback: the
    # batch is retained and retried on the reporter's backoff ladder.
    class Socket
      Result = Local::Result
      FALLBACK_AFTER = 3
      MAX_REPLY_BYTES = 1 << 20

      def initialize(config, path: nil)
        @config = config
        @path = path || config.writer_socket_path
        @missing = 0
        @fallback = nil
      end

      attr_reader :path

      def fallback? = !@fallback.nil?

      def deliver(records, dropped: 0, dropped_bytes: 0, backpressure_factor: 1.0, batch_id: nil)
        return @fallback.deliver(records, dropped: dropped, dropped_bytes: dropped_bytes,
                                 backpressure_factor: backpressure_factor, batch_id: batch_id) if @fallback

        payload = Zlib.gzip(JSON.generate(batch_id: batch_id, records: records, dropped: dropped,
                                          dropped_bytes: dropped_bytes, backpressure_factor: backpressure_factor))
        reply = exchange(payload)
        @missing = 0
        Result.new(**reply.slice("ok", "status", "accepted", "rejected", "rejections", "error", "retryable_error").transform_keys(&:to_sym))
      rescue Errno::ENOENT => e
        # No socket file: nobody is listening and nobody is about to be.
        @missing += 1
        if @missing >= FALLBACK_AFTER
          Railwatch.debug { "no writer at #{@path} after #{@missing} attempts; writing batches in-process from now on" }
          @fallback = Local.new(@config)
          return deliver(records, dropped: dropped, dropped_bytes: dropped_bytes,
                         backpressure_factor: backpressure_factor, batch_id: batch_id)
        end
        Result.new(ok: false, error: "writer socket missing: #{e.message}", retryable_error: true)
      rescue SystemCallError, IOError, Zlib::Error, JSON::ParserError, Timeout::Error => e
        Railwatch.debug { "writer delivery failed: #{e.class}: #{e.message}" }
        Result.new(ok: false, error: "#{e.class}: #{e.message}", retryable_error: true)
      end

      def ping
        UNIXSocket.new(@path).close
        true
      rescue SystemCallError
        false
      end

      def unauthorized? = false
      def reset_after_fork! = self

      private

      def exchange(payload)
        UNIXSocket.open(@path) do |sock|
          deadline = Clock.monotonic + @config.timeout
          sock.write([ payload.bytesize ].pack("N"), payload)
          sock.flush
          header = read_exactly(sock, 4, deadline)
          length = header.unpack1("N")
          raise IOError, "writer reply too large (#{length} bytes)" if length > MAX_REPLY_BYTES

          JSON.parse(read_exactly(sock, length, deadline))
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
