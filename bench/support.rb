# frozen_string_literal: true

# Shared setup for every script in bench/. Requiring it boots the dummy app
# on SQLite in the test environment with Lantern enabled and pointed at a
# port nothing listens on, loads the schema, seeds a few rows, and makes
# the reporter drop records instead of shipping them, so a script measures
# in-process cost only.
#
# It also records every ActiveSupport::Notifications subscriber the gem
# installs, so a script can take the gem genuinely out of the way
# (lantern_off!) and put it back (lantern_on!). Flipping config.enabled is
# not enough for a baseline: the subscribers still receive every event, and
# a log Capture left on the broadcast logger still costs.
#
# Scripts that drive requests get BenchController at /bench/:action and a
# Rack::Test DRIVER; the dummy app's own routes (/widgets, /many, /cached,
# /boom, ...) stay mounted.
ENV["RAILS_ENV"] = "test"
ENV["LANTERN_TOKEN"] ||= "bench"
ENV["LANTERN_INGEST_URL"] ||= "http://127.0.0.1:9"

require "active_support"
require "active_support/notifications"

LANTERN_SUBSCRIPTIONS = []
module TrackLanternSubscriptions
  def subscribe(pattern = nil, callback = nil, &block)
    sub = super
    LANTERN_SUBSCRIPTIONS << [ pattern, sub, :subscribe ] if from_lantern?
    sub
  end

  def monotonic_subscribe(pattern = nil, callback = nil, &block)
    sub = super
    LANTERN_SUBSCRIPTIONS << [ pattern, sub, :monotonic_subscribe ] if from_lantern?
    sub
  end

  private

  def from_lantern? = caller_locations(2, 3).any? { |l| l.path.include?("/lib/lantern/") }
end
ActiveSupport::Notifications.singleton_class.prepend(TrackLanternSubscriptions)

require_relative "../spec/dummy/config/environment"
require "rack/test"
require "json"

abort "Lantern must be enabled for benchmarks (LANTERN_ENABLED is off)" unless Lantern.enabled?

ActiveRecord::Schema.verbose = false
load File.expand_path("../spec/dummy/db/schema.rb", __dir__)
3.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) }
User.create!(name: "bench", email: "bench@example.com")

# Swallow transport work entirely; the reporter thread is measured by
# bench/transport_cost.rb and bench/load/run.sh, not here.
Lantern.reporter.define_singleton_method(:flush) { @buffer.drain; nil }

CAPTURE = Rails.logger.broadcasts.find { |l| l.is_a?(Lantern::Subscribers::Logs::Capture) }

def lantern_off!
  LANTERN_SUBSCRIPTIONS.each { |_, sub, _| ActiveSupport::Notifications.unsubscribe(sub) }
  Rails.logger.stop_broadcasting_to(CAPTURE) if CAPTURE
  Lantern.config.enabled = false
end

def lantern_on!
  LANTERN_SUBSCRIPTIONS.map! do |pattern, sub, how|
    delegate = sub.instance_variable_get(:@delegate)
    [ pattern, ActiveSupport::Notifications.public_send(how, pattern, delegate), how ]
  end
  Rails.logger.broadcast_to(CAPTURE) if CAPTURE
  Lantern.config.enabled = true
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
Rails.application.routes.append { get "bench/:action", controller: "bench" }
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

def print_rows(rows, label_width: 72)
  puts format("%-#{label_width}s %9s %7s", "", "cpu µs", "allocs")
  rows.each { |label, (us, allocs)| puts format("%-#{label_width}s %9.2f %7d", label, us, allocs) }
end
