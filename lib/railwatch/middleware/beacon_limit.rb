# frozen_string_literal: true

module Railwatch
  module Middleware
    # Refuses an oversized beacon body before Rails parses it. The check
    # cannot live in BeaconController: ActionController parses the params
    # (ParamsWrapper, parameter filtering for the log line) before any
    # before_action, and Request#content_length on a chunked body reads it
    # whole. In the engine's own stack, so it sees only the beacon route.
    class BeaconLimit
      MAX_BYTES = 256 * 1024

      def initialize(app, limit = MAX_BYTES)
        @app = app
        @limit = limit
      end

      def call(env)
        return too_large if env["CONTENT_LENGTH"].to_i > @limit
        return @app.call(env) if env["CONTENT_LENGTH"] || !(input = env["rack.input"])

        # Chunked: no length up front, so read at most one byte past the
        # limit and hand the rest of the stack a body it can read again.
        body = read_bounded(input)
        return too_large if body.bytesize > @limit

        env["rack.input"] = StringIO.new(body)
        env["CONTENT_LENGTH"] = body.bytesize.to_s
        env.delete("HTTP_TRANSFER_ENCODING")
        @app.call(env)
      end

      private

      # Rack lets read(n) return fewer than n bytes before the end, so keep
      # reading until the end or one byte past the limit, never further.
      def read_bounded(input)
        body = +"".b
        while body.bytesize <= @limit
          chunk = input.read(@limit + 1 - body.bytesize) or break
          break if chunk.empty?

          body << chunk
        end
        body
      end

      def too_large
        [ 413, { "content-type" => "text/plain" }, [] ]
      end
    end
  end
end
