# Where does the per-query cost go? Runs sql.active_record N times with a
# stackprof sample, and reports the top frames inside Lantern.
ENV["RAILS_ENV"] = "test"; ENV["LANTERN_TOKEN"] = "bench"; ENV["LANTERN_INGEST_URL"] = "http://127.0.0.1:9"
require_relative "../spec/dummy/config/environment"
require "stackprof"
ActiveRecord::Schema.verbose = false
load File.expand_path("../spec/dummy/db/schema.rb", __dir__)
3.times { |i| Widget.create!(name: "w#{i}") }
Lantern.reporter.define_singleton_method(:flush) { @buffer.drain; nil }
exe = Lantern.start_execution(source: :request, sample_kind: :requests, preview: "bench")
exe.enter_stage(:action)
N = 20_000
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
StackProf.run(mode: :wall, interval: 100, out: "/tmp/lantern_query.dump") do
  N.times { |i| Widget.where(id: i % 3 + 1).to_a }
end
puts "per query total: #{((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1_000_000 / N).round(1)}µs"
report = StackProf::Report.new(Marshal.load(File.binread("/tmp/lantern_query.dump")))
io = StringIO.new; report.print_text(false, 40, nil, nil, nil, nil, io)
puts io.string.lines.select { |l| l =~ /lantern|Lantern/ }.first(25)
