# frozen_string_literal: true

# Shared setup for every script in bench/. Requiring it boots the dummy app
# on SQLite in the test environment with Railwatch enabled and pointed at a
# port nothing listens on, loads the schema, seeds a few rows, and makes
# the reporter drop records instead of shipping them, so a script measures
# in-process cost only.
#
# It also records every ActiveSupport::Notifications subscriber the gem
# installs, so a script can take the gem genuinely out of the way
# (railwatch_off!) and put it back (railwatch_on!). Flipping config.enabled is
# not enough for a baseline: the subscribers still receive every event, and
# a log Capture left on the broadcast logger still costs.
#
# Scripts that drive requests get BenchController at /bench/:action and a
# Rack::Test DRIVER; the dummy app's own routes (/widgets, /many, /cached,
# /boom, ...) stay mounted.
ENV["RAILS_ENV"] = "test"
ENV["RAILWATCH_TOKEN"] ||= "bench"
ENV["RAILWATCH_INGEST_URL"] ||= "http://127.0.0.1:9"

require "active_support"
require "active_support/notifications"

RAILWATCH_SUBSCRIPTIONS = []
module TrackRailwatchSubscriptions
  def subscribe(pattern = nil, callback = nil, &block)
    sub = super
    RAILWATCH_SUBSCRIPTIONS << [ pattern, sub, :subscribe ] if from_railwatch?
    sub
  end

  def monotonic_subscribe(pattern = nil, callback = nil, &block)
    sub = super
    RAILWATCH_SUBSCRIPTIONS << [ pattern, sub, :monotonic_subscribe ] if from_railwatch?
    sub
  end

  private

  def from_railwatch? = caller_locations(2, 3).any? { |l| l.path.include?("/lib/railwatch/") }
end
ActiveSupport::Notifications.singleton_class.prepend(TrackRailwatchSubscriptions)

require_relative "../spec/dummy/config/environment"
require "rack/test"
require "json"

abort "Railwatch must be enabled for benchmarks (RAILWATCH_ENABLED is off)" unless Railwatch.enabled?

ActiveRecord::Schema.verbose = false
load File.expand_path("../spec/dummy/db/schema.rb", __dir__)
3.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) }
User.create!(name: "bench", email: "bench@example.com")

# Swallow transport work entirely; the reporter thread is measured by
# bench/transport_cost.rb and bench/load/run.sh, not here.
Railwatch.reporter.define_singleton_method(:flush) { @buffer.drain; nil }

CAPTURE = Rails.logger.broadcasts.find { |l| l.is_a?(Railwatch::Subscribers::Logs::Capture) } or
  abort "Railwatch's log Capture is not on Rails.logger; the log path would go unmeasured"

def railwatch_off!
  RAILWATCH_SUBSCRIPTIONS.each { |_, sub, _| ActiveSupport::Notifications.unsubscribe(sub) }
  Rails.logger.stop_broadcasting_to(CAPTURE)
  Railwatch.config.enabled = false
end

def railwatch_on!
  RAILWATCH_SUBSCRIPTIONS.map! do |pattern, sub, how|
    delegate = sub.instance_variable_get(:@delegate)
    [ pattern, ActiveSupport::Notifications.public_send(how, pattern, delegate), how ]
  end
  Rails.logger.broadcast_to(CAPTURE)
  Railwatch.config.enabled = true
end

# Keep records out of the reporter entirely (what these scripts measure is
# upstream of it), or collect them into `into` for a script that prices them.
def stub_reporter_writes!(into = nil)
  Railwatch.reporter.define_singleton_method(:write) { |record, _bytes = nil| into << record if into }
  Railwatch.reporter.define_singleton_method(:write_now) { |record| into << record if into }
end

# Cheap request shapes for the scripts that need something besides the
# dummy app's own actions. `uncached` matters: Rails' per-request query
# cache would otherwise collapse repeated statements into a handful of real
# ones, and the gem's cost is per real query.
class BenchController < ActionController::Base
  def trivial = render(plain: "ok")

  def queries
    ActiveRecord::Base.uncached { Integer(params.fetch(:n, 20)).times { |i| Widget.where(id: i % 3 + 1).to_a } }
    render plain: "ok"
  end

  def cached_queries
    Integer(params.fetch(:n, 20)).times { |i| Widget.where(id: i % 3 + 1).to_a }
    render plain: "ok"
  end

  def logs
    Integer(params.fetch(:n, 20)).times { |i| Rails.logger.info("bench line #{i} for a widget") }
    render plain: "ok"
  end

  def cache
    Integer(params.fetch(:n, 20)).times { |i| Rails.cache.fetch("bench/#{i % 5}") { i } }
    render plain: "ok"
  end
end
Rails.application.routes.append do
  %w[trivial queries cached_queries logs cache].each { |action| get "bench/#{action}", to: "bench##{action}" }
end
Rails.application.reload_routes!

class Driver
  include Rack::Test::Methods
  def app = Rails.application
end
DRIVER = Driver.new

def cpu_us = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID, :microsecond)

# CPU microseconds and allocations per call of the block, after warm-up.
def per_call(n = 20_000)
  2.times { yield }
  GC.start
  a0 = GC.stat(:total_allocated_objects)
  t0 = cpu_us
  n.times { yield }
  [ (cpu_us - t0) / n.to_f, (GC.stat(:total_allocated_objects) - a0) / n ]
end

# One batch of requests with GC held off: CPU µs per request on this thread
# and allocations per request.
def request_batch(path, size)
  GC.start
  GC.disable
  a0 = GC.stat(:total_allocated_objects)
  t0 = cpu_us
  size.times { DRIVER.get(path) }
  [ (cpu_us - t0) / size.to_f, (GC.stat(:total_allocated_objects) - a0) / size ]
ensure
  GC.enable
end

# Off and on alternate every batch so background load lands on both
# equally. Returns [off, on], each { min:, p50:, allocs: } over the rounds;
# allocations are deterministic and taken as the minimum.
def interleaved_measure(path, rounds:, batch:)
  railwatch_off!
  20.times { DRIVER.get(path) }
  railwatch_on!
  20.times { DRIVER.get(path) }
  off = []
  on = []
  rounds.times do
    railwatch_off!
    off << request_batch(path, batch)
    railwatch_on!
    on << request_batch(path, batch)
  end
  summarize = lambda do |samples|
    times = samples.map(&:first).sort
    { min: times.first, p50: times[times.size / 2], allocs: samples.map(&:last).min }
  end
  [ summarize.call(off), summarize.call(on) ]
end

def print_rows(rows, label_width: 72)
  puts format("%-#{label_width}s %9s %7s", "", "cpu µs", "allocs")
  rows.each { |label, (us, allocs)| puts format("%-#{label_width}s %9.2f %7d", label, us, allocs) }
end
