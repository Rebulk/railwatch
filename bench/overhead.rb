# frozen_string_literal: true

# Overhead gate. Boots the dummy app, drives a request that runs ~200 queries
# with Lantern off and on, and reports added latency, allocations, and
# per-query cost. Fails (exit 1) when any limit in LIMITS is exceeded.
#
#   bundle exec ruby bench/overhead.rb
#
ENV["RAILS_ENV"] = "test"
ENV["LANTERN_TOKEN"] = "bench"
ENV["LANTERN_INGEST_URL"] = "http://127.0.0.1:9" # nothing listens; transport must not add latency
require_relative "../spec/dummy/config/environment"
require "rack/test"
require "benchmark"

ActiveRecord::Schema.verbose = false
load File.expand_path("../spec/dummy/db/schema.rb", __dir__)

LIMITS = { p50_ms: 1.0, per_query_us: 8.0, allocations: 3_000 }.freeze
QUERIES = 200
ROUNDS = 300

class BenchController < ActionController::Base
  def index
    QUERIES.times { |i| Widget.where(id: i % 3 + 1).to_a }
    render plain: "ok"
  end
end
Rails.application.routes.draw { get "bench", to: "bench#index" }

3.times { |i| Widget.create!(name: "w#{i}") }

class Driver
  include Rack::Test::Methods
  def app = Rails.application
end
driver = Driver.new

# Swallow transport work entirely so we measure only in-process cost.
Lantern.reporter.define_singleton_method(:flush) { @buffer.drain; nil }

def measure(driver, rounds)
  20.times { driver.get "/bench" } # warm up
  times = []
  allocs = []
  rounds.times do
    a0 = GC.stat(:total_allocated_objects)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    driver.get "/bench"
    times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000
    allocs << GC.stat(:total_allocated_objects) - a0
  end
  sorted = times.sort
  { p50: sorted[rounds / 2], p95: sorted[(rounds * 0.95).to_i], allocs: allocs.sum / allocs.size }
end

GC.disable
Lantern.config.enabled = false
off = measure(driver, ROUNDS)
Lantern.config.enabled = true
on = measure(driver, ROUNDS)
GC.enable

added_p50 = on[:p50] - off[:p50]
added_allocs = on[:allocs] - off[:allocs]
per_query_us = (added_p50 * 1000) / QUERIES

puts format("%-28s %10s %10s %10s", "", "off", "on", "added")
puts format("%-28s %10.3f %10.3f %10.3f", "request p50 (ms)", off[:p50], on[:p50], added_p50)
puts format("%-28s %10.3f %10.3f %10.3f", "request p95 (ms)", off[:p95], on[:p95], on[:p95] - off[:p95])
puts format("%-28s %10d %10d %10d", "allocations / request", off[:allocs], on[:allocs], added_allocs)
puts format("%-28s %10s %10s %10.2f", "added µs per query", "", "", per_query_us)

failures = []
failures << "added p50 #{added_p50.round(3)}ms > #{LIMITS[:p50_ms]}ms" if added_p50 > LIMITS[:p50_ms]
failures << "per query #{per_query_us.round(2)}µs > #{LIMITS[:per_query_us]}µs" if per_query_us > LIMITS[:per_query_us]
failures << "allocations #{added_allocs} > #{LIMITS[:allocations]}" if added_allocs > LIMITS[:allocations]

if failures.empty?
  puts "\nOVERHEAD GATE PASSED"
else
  puts "\nOVERHEAD GATE FAILED: #{failures.join('; ')}"
  exit 1
end
