# frozen_string_literal: true

# Attribution: which Nightrail frames the per-request and per-query cost
# land in. Runs memory_profiler (allocations by gem file:line) and
# stackprof (CPU by frame) over the trivial request and the 20-query
# request and prints only the Nightrail lines, then stackprof (wall) over
# three hot paths in isolation: the middleware end to end, one
# Rails.cache.fetch, and one Rails.logger.info line.
#
#   bundle exec ruby bench/profile.rb
require_relative "support"
require "memory_profiler"
require "stackprof"

GEM = File.expand_path("../lib", __dir__) + "/"

def stackprof_lines(mode:, interval:, top:)
  path = "/tmp/nightrail_bench_profile.dump"
  StackProf.run(mode: mode, interval: interval, out: path) { yield }
  report = StackProf::Report.new(Marshal.load(File.binread(path)))
  io = StringIO.new
  report.print_text(false, top, nil, nil, nil, nil, io)
  io.string.lines
end

{ "trivial request" => "/bench/trivial", "20 uncached queries" => "/bench/queries?n=20" }.each do |label, path|
  50.times { DRIVER.get(path) }
  report = MemoryProfiler.report { 20.times { DRIVER.get(path) } }
  nightrail = report.allocated_objects_by_location.select { |h| h[:data].start_with?(GEM) }
  puts "\n== #{label}: #{report.total_allocated / 20} objects/request, #{nightrail.sum { |h| h[:count] } / 20} allocated directly in lib/nightrail"
  nightrail.first(14).each { |h| puts format("  %5d  %s", h[:count] / 20, h[:data].delete_prefix(GEM)) }

  lines = stackprof_lines(mode: :cpu, interval: 200, top: 60) { 300.times { DRIVER.get(path) } }
  puts "  cpu samples: #{lines.find { |l| l.include?('TOTAL') }&.strip}"
  puts lines.select { |l| l.include?("nightrail/") || l.include?("Nightrail") }.first(14).map { |l| "  " + l.rstrip }
end

def profile(label, n, top: 22)
  2.times { yield }
  puts "\n== #{label}"
  puts stackprof_lines(mode: :wall, interval: 20, top: top) { n.times { yield } }.drop(1).map(&:rstrip)
end

stub_reporter_writes!
env = Rack::MockRequest.env_for("/widgets?x=1", "HTTP_USER_AGENT" => "bench/1.0", "HTTP_ACCEPT" => "text/html", "HTTP_COOKIE" => "a=b", "HTTP_HOST" => "example.org")
mw = Nightrail::Middleware::Request.new(->(_e) { [ 200, { "Content-Length" => "2" }, [ "ok" ] ] })
Current.user = User.first
profile("middleware call, no-op app", 20_000) { mw.call(env.dup) }

exe = Nightrail.start_execution(source: :request, sample_kind: :requests, preview: "bench")
exe.enter_stage(:action)
Rails.cache.write("bench/1", 1)
profile("Rails.cache.fetch hit inside a sampled-in execution", 30_000) { Rails.cache.fetch("bench/1") { 1 }; exe.records.clear }
profile("Rails.logger.info inside a sampled-in execution", 30_000) { Rails.logger.info("listed 3 widgets for a bench"); exe.records.clear }
