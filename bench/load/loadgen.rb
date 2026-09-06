# frozen_string_literal: true

# Closed-loop HTTP load generator: N threads each hammer one URL over a
# kept-alive connection for a duration, then latency percentiles are
# printed. Ruby threads are fine here because the client is I/O bound and
# the server under test is a separate process; it saturates a 4-thread
# Puma from 4 client threads on the same box.
#
#   ruby bench/load/loadgen.rb -u http://127.0.0.1:9292/widgets -c 4 -d 8
require "net/http"
require "optparse"

url = "http://127.0.0.1:9292/widgets"
conc = 4
duration = 8.0
OptionParser.new do |o|
  o.on("-u URL", "--url URL") { |v| url = v }
  o.on("-c N", "--concurrency N", Integer) { |v| conc = v }
  o.on("-d SECONDS", "--duration SECONDS", Float) { |v| duration = v }
end.parse!
uri = URI(url)

def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
deadline = now + duration
workers = Array.new(conc) do
  Thread.new do
    latencies = []
    errors = 0
    non200 = 0
    http = nil
    while now < deadline
      t0 = now
      begin
        # A dropped keep-alive connection is counted once and replaced, not
        # reused for every request after it.
        http ||= Net::HTTP.start(uri.host, uri.port)
        non200 += 1 unless http.get(uri.request_uri).is_a?(Net::HTTPOK)
        latencies << (now - t0) * 1000
      rescue StandardError
        errors += 1
        http&.finish rescue nil
        http = nil
        sleep 0.05
      end
    end
    http&.finish
    [ latencies, errors, non200 ]
  end
end
results = workers.map(&:value)
lat = results.flat_map(&:first).sort
errors = results.sum { |r| r[1] }
non200 = results.sum { |r| r[2] }
abort "no successful requests; errors: #{errors}" if lat.empty?
pct = ->(q) { lat[((lat.size - 1) * q).round] }
puts format("%s c=%d: %d req in %.0fs = %.0f rps; mean %.2fms p50 %.2fms p95 %.2fms p99 %.2fms max %.2fms; errors %d non200 %d",
            url, conc, lat.size, duration, lat.size / duration, lat.sum / lat.size, pct.(0.5), pct.(0.95), pct.(0.99), lat.last, errors, non200)
