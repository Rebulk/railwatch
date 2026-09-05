# frozen_string_literal: true

# Overhead gate. Boots the dummy app on SQLite, drives three request shapes
# with Lantern genuinely out of the way and then in, interleaved, and
# reports added CPU time on the request thread and added allocations.
# Fails (exit 1) when any limit in LIMITS is exceeded.
#
# "Off" means off: every ActiveSupport::Notifications subscriber the gem
# installed is unsubscribed and its log Capture is removed from the
# broadcast logger. Flipping config.enabled at runtime is not enough -- the
# subscribers still receive every event, and a Capture logger left at DEBUG
# makes every framework LogSubscriber format lines nobody stores -- and a
# baseline measured that way hid most of the gem's cost.
#
#   bundle exec ruby bench/overhead.rb
#
ENV["RAILS_ENV"] = "test"
ENV["LANTERN_TOKEN"] = "bench"
ENV["LANTERN_INGEST_URL"] = "http://127.0.0.1:9" # nothing listens; transport must not add latency

require "active_support"
require "active_support/notifications"
SUBSCRIPTIONS = []
module TrackLanternSubscriptions
  def subscribe(pattern = nil, callback = nil, &block)
    sub = super
    SUBSCRIPTIONS << [ pattern, sub ] if caller_locations(1, 3).any? { |l| l.path.include?("/lib/lantern/") }
    sub
  end

  def monotonic_subscribe(pattern = nil, callback = nil, &block)
    sub = super
    SUBSCRIPTIONS << [ pattern, sub ] if caller_locations(1, 3).any? { |l| l.path.include?("/lib/lantern/") }
    sub
  end
end
ActiveSupport::Notifications.singleton_class.prepend(TrackLanternSubscriptions)

require_relative "../spec/dummy/config/environment"
require "rack/test"

ActiveRecord::Schema.verbose = false
load File.expand_path("../spec/dummy/db/schema.rb", __dir__)
3.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) }
User.create!(name: "bench", email: "bench@example.com")

# Swallow transport work entirely so we measure only in-process cost.
Lantern.reporter.define_singleton_method(:flush) { @buffer.drain; nil }
CAPTURE = Rails.logger.broadcasts.find { |l| l.is_a?(Lantern::Subscribers::Logs::Capture) }

def lantern_off!
  SUBSCRIPTIONS.each { |_, sub| ActiveSupport::Notifications.unsubscribe(sub) }
  Rails.logger.stop_broadcasting_to(CAPTURE)
  Lantern.config.enabled = false
end

def lantern_on!
  SUBSCRIPTIONS.map! do |pattern, sub|
    delegate = sub.instance_variable_get(:@delegate)
    [ pattern, ActiveSupport::Notifications.subscribe(pattern, delegate) ]
  end
  Rails.logger.broadcast_to(CAPTURE)
  Lantern.config.enabled = true
end

# Limits are on CPU time, not wall time, so the gate is stable on a loaded
# CI box: wall time would swing by tens of ms with other processes running.
# Each is roughly double what an idle core measures (see docs/faq.md), so a
# slow runner passes and a real regression does not.
LIMITS = {
  "trivial (no queries)" => { p50_us: 900, allocations: 400 },
  "20 sqlite queries" => { p50_us: 3_000, allocations: 1_000 },
  "widgets (n+1, 7 queries, 1 log)" => { p50_us: 2_000, allocations: 500 }
}.freeze
SHAPES = {
  "trivial (no queries)" => "/bench/trivial",
  "20 sqlite queries" => "/bench/queries",
  "widgets (n+1, 7 queries, 1 log)" => "/widgets"
}.freeze
ROUNDS = 9
BATCH = 15

class BenchController < ActionController::Base
  def trivial = render(plain: "ok")

  # uncached: Rails' per-request query cache would otherwise collapse these
  # into three real statements, and the gem's cost is per real query.
  def queries
    ActiveRecord::Base.uncached { 20.times { |i| Widget.where(id: i % 3 + 1).to_a } }
    render plain: "ok"
  end
end
Rails.application.routes.draw do
  get "bench/trivial", to: "bench#trivial"
  get "bench/queries", to: "bench#queries"
  get "widgets", to: "widgets#index"
end

class Driver
  include Rack::Test::Methods
  def app = Rails.application
end
DRIVER = Driver.new

def cpu_us = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID, :microsecond)

def sample(path)
  GC.start
  GC.disable
  a0 = GC.stat(:total_allocated_objects)
  t0 = cpu_us
  BATCH.times { DRIVER.get(path) }
  [ (cpu_us - t0) / BATCH.to_f, (GC.stat(:total_allocated_objects) - a0) / BATCH ]
ensure
  GC.enable
end

def summarize(samples)
  times = samples.map(&:first).sort
  { p50: times[times.size / 2], min: times.first, allocs: samples.map(&:last).min }
end

# Off and on alternate every batch so background load lands on both
# equally; the median of the rounds is what the gate judges. Allocations
# are deterministic and taken as the minimum.
def measure(path)
  lantern_off!
  20.times { DRIVER.get(path) }
  lantern_on!
  20.times { DRIVER.get(path) }
  off = []
  on = []
  ROUNDS.times do
    lantern_off!
    off << sample(path)
    lantern_on!
    on << sample(path)
  end
  [ summarize(off), summarize(on) ]
end

failures = []
puts format("%-34s %9s %9s %9s %9s | %7s %7s %7s", "added by Lantern (sampled in)", "off p50", "on p50", "Δ p50 µs", "Δ min µs", "off al", "on al", "Δ al")
SHAPES.each do |name, path|
  off, on = measure(path)
  added = on[:p50] - off[:p50]
  added_min = on[:min] - off[:min]
  added_allocs = on[:allocs] - off[:allocs]
  puts format("%-34s %9.0f %9.0f %+9.0f %+9.0f | %7d %7d %+7d", name, off[:p50], on[:p50], added, added_min, off[:allocs], on[:allocs], added_allocs)
  limit = LIMITS.fetch(name)
  failures << "#{name}: added p50 #{added.round}µs > #{limit[:p50_us]}µs" if added > limit[:p50_us]
  failures << "#{name}: added allocations #{added_allocs} > #{limit[:allocations]}" if added_allocs > limit[:allocations]
end

# The head-sampled-out path, which is what most of a sampled application's
# traffic takes. Reported, not gated: it is a fraction of the sampled-in
# cost and sits under this benchmark's noise floor on a shared box. The
# allocation count is the number to watch -- it moves only if the gem
# starts building records it used to skip.
Lantern.config.sample[:requests] = 0.0
off, on = measure("/widgets")
puts format("%-34s %9.0f %9.0f %+9.0f %+9.0f | %7d %7d %+7d", "widgets, sampled out", off[:p50], on[:p50], on[:p50] - off[:p50], on[:min] - off[:min], off[:allocs], on[:allocs], on[:allocs] - off[:allocs])
Lantern.config.sample[:requests] = 1.0

puts "Rails.logger.debug? with Lantern installed: #{Rails.logger.debug?} (must stay false, or every framework log line is formatted)"
failures << "Lantern's log capture turned Rails.logger.debug? on" if Rails.logger.debug?

if failures.empty?
  puts "\nOVERHEAD GATE PASSED"
else
  puts "\nOVERHEAD GATE FAILED: #{failures.join('; ')}"
  exit 1
end
