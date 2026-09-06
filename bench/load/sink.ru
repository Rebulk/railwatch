# frozen_string_literal: true

# A stand-in ingest endpoint for load tests: reads each batch, counts
# records, bytes, and the X-Nightrail-Dropped header, answers 200.
#
#   bundle exec puma -p 9393 -t 2:2 -q bench/load/sink.ru
#   curl http://127.0.0.1:9393/stats          # {"batches":..,"bytes":..,"dropped":..,"records":..}
#   curl 'http://127.0.0.1:9393/stats?reset'  # read and zero
require "json"
require "zlib"

counts = Hash.new(0)
run lambda { |env|
  body = env["rack.input"].read
  if env["PATH_INFO"] == "/stats"
    out = JSON.generate(counts)
    counts.replace(Hash.new(0)) if env["QUERY_STRING"] == "reset"
    [ 200, { "content-type" => "application/json" }, [ out ] ]
  else
    counts[:batches] += 1
    counts[:bytes] += body.bytesize
    counts[:dropped] += env["HTTP_X_NIGHTRAIL_DROPPED"].to_i
    counts[:records] += (env["HTTP_CONTENT_ENCODING"] == "gzip" ? Zlib.gunzip(body) : body).count("\n")
    [ 200, { "content-type" => "application/json" }, [ '{"accepted":0,"rejected":0}' ] ]
  end
}
