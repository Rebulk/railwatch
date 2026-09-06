# frozen_string_literal: true

# The wider version of the overhead gate: what including the gem costs per
# request shape, ungated, over more shapes and a configurable number of
# rounds. Off and on are interleaved in one process so machine drift hits
# both equally; per-request CPU time on the request thread (min and median
# over ROUNDS) and allocations are reported.
#
#   bundle exec ruby bench/cost_by_shape.rb
#   ROUNDS=15 bundle exec ruby bench/cost_by_shape.rb
#   LANTERN_REQUEST_SAMPLE_RATE=0 bundle exec ruby bench/cost_by_shape.rb   # head-sampled-out path
#   BENCH_OUT=/tmp/after.json bundle exec ruby bench/cost_by_shape.rb      # keep the numbers
#
# To compare before and after a change, run it on both checkouts with
# BENCH_OUT and diff the two files; do not compare against numbers from
# another day or another box.
require_relative "support"

SHAPES = {
  "trivial (no queries)" => "/bench/trivial",
  "20 sqlite queries" => "/bench/queries?n=20",
  "100 sqlite queries" => "/bench/queries?n=100",
  "100 query-cache hits" => "/bench/cached_queries?n=100",
  "20 log lines" => "/bench/logs?n=20",
  "20 cache fetches" => "/bench/cache?n=20",
  "widgets (n+1, 7 q, 1 log)" => "/widgets",
  "many (7 view renders)" => "/many"
}.freeze

ROUNDS = Integer(ENV.fetch("ROUNDS", 9))
BATCH = 15

def measure(path) = interleaved_measure(path, rounds: ROUNDS, batch: BATCH)

label = Lantern.config.sample[:requests].zero? ? "sampled out" : "sampled in"
puts "Lantern #{label}: per-request CPU µs on the request thread (off = gem unsubscribed), #{ROUNDS} interleaved rounds x #{BATCH}"
puts format("%-28s %9s %9s %9s | %9s %9s %9s | %7s %7s %7s", "shape", "off min", "on min", "Δ min", "off p50", "on p50", "Δ p50", "off al", "on al", "Δ al")
results = {}
SHAPES.each do |name, path|
  off, on = measure(path)
  results[name] = { off: off, on: on }
  puts format("%-28s %9.0f %9.0f %+9.0f | %9.0f %9.0f %+9.0f | %7d %7d %+7d",
              name, off[:min], on[:min], on[:min] - off[:min], off[:p50], on[:p50], on[:p50] - off[:p50],
              off[:allocs], on[:allocs], on[:allocs] - off[:allocs])
end
File.write(ENV["BENCH_OUT"], JSON.generate(label: label, results: results)) if ENV["BENCH_OUT"]
