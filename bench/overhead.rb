# frozen_string_literal: true

# Overhead gate. Boots the dummy app on SQLite, drives three request shapes
# with Nightrail genuinely out of the way and then in, interleaved, and
# reports added CPU time on the request thread and added allocations.
# Fails (exit 1) when any limit in LIMITS is exceeded.
#
# "Off" means off: every ActiveSupport::Notifications subscriber the gem
# installed is unsubscribed and its log Capture is removed from the
# broadcast logger (see bench/support.rb). Flipping config.enabled at
# runtime is not enough -- the subscribers still receive every event, and
# a Capture logger left at DEBUG makes every framework LogSubscriber format
# lines nobody stores -- and a baseline measured that way hid most of the
# gem's cost.
#
#   bundle exec ruby bench/overhead.rb
#
require_relative "support"

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
  "20 sqlite queries" => "/bench/queries?n=20",
  "widgets (n+1, 7 queries, 1 log)" => "/widgets"
}.freeze
ROUNDS = 9
BATCH = 15

# The median of the interleaved rounds is what the gate judges.
def measure(path) = interleaved_measure(path, rounds: ROUNDS, batch: BATCH)

failures = []
puts format("%-34s %9s %9s %9s %9s | %7s %7s %7s", "added by Nightrail (sampled in)", "off p50", "on p50", "Δ p50 µs", "Δ min µs", "off al", "on al", "Δ al")
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
Nightrail.config.sample[:requests] = 0.0
off, on = measure("/widgets")
puts format("%-34s %9.0f %9.0f %+9.0f %+9.0f | %7d %7d %+7d", "widgets, sampled out", off[:p50], on[:p50], on[:p50] - off[:p50], on[:min] - off[:min], off[:allocs], on[:allocs], on[:allocs] - off[:allocs])
Nightrail.config.sample[:requests] = 1.0

puts "Rails.logger.debug? with Nightrail installed: #{Rails.logger.debug?} (must stay false, or every framework log line is formatted)"
failures << "Nightrail's log capture turned Rails.logger.debug? on" if Rails.logger.debug?

if failures.empty?
  puts "\nOVERHEAD GATE PASSED"
else
  puts "\nOVERHEAD GATE FAILED: #{failures.join('; ')}"
  exit 1
end
