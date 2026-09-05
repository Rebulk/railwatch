# frozen_string_literal: true

# The cost that is NOT on the request thread: serializing and gzipping a
# batch on the reporter thread (at the gzip level the transport uses and
# the alternatives), bytes on the wire, heap held by buffered records, and
# how much a reporter thread encoding non-stop slows a request thread
# through the GVL. Captures a realistic mix of records by driving the
# dummy app, then prices a flush of them.
#
#   bundle exec ruby bench/transport_cost.rb
require_relative "support"
require "zlib"
require "objspace"

captured = []
Lantern.reporter.define_singleton_method(:write) { |r, _bytes = nil| captured << r }
Lantern.reporter.define_singleton_method(:write_now) { |r| captured << r }

10.times do
  DRIVER.get "/widgets"
  DRIVER.get "/many"
  DRIVER.get "/cached"
  DRIVER.get "/bench/queries?n=20"
  DRIVER.get "/boom"
end
requests = captured.count { |r| r[:t] == "request" }
puts "captured #{captured.size} records from #{requests} requests (#{(captured.size / requests.to_f).round(1)} per request)"
mix = captured.group_by { |r| r[:t] }.transform_values(&:size).sort_by { |_, n| -n }
puts "mix: " + mix.map { |t, n| "#{t}=#{n}" }.join(" ")

transport = Lantern::Transport::Http.new(Lantern.config)
# encode returns [body, records written, records over batch_bytes, bytes over].
encode = ->(records) { transport.send(:encode, records).first }
raw = captured.sum { |r| JSON.generate(r).bytesize + 1 }
gz = encode.(captured).bytesize
puts format("wire: %d bytes raw NDJSON, %d bytes gzipped (%.1fx); %d raw / %d gz bytes per record; %d gz bytes per request",
            raw, gz, raw.to_f / gz, raw / captured.size, gz / captured.size, gz / requests)
by_type = captured.group_by { |r| r[:t] }.transform_values { |rs| rs.sum { |r| JSON.generate(r).bytesize } / rs.size }
puts "avg raw bytes by type: " + by_type.sort_by { |_, b| -b }.map { |t, b| "#{t}=#{b}" }.join(" ")

batch = captured.first(500)
def cpu_ms = Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID, :float_millisecond)
def timed_ms(n = 10)
  3.times { yield }
  t0 = cpu_ms
  n.times { yield }
  (cpu_ms - t0) / n
end
def encode_at(batch, level)
  io = StringIO.new
  gz = Zlib::GzipWriter.new(io, level)
  batch.each { |r| gz.write(JSON.generate(r)); gz.write("\n") }
  gz.close
  io.string
end

puts "\nreporter-thread CPU to encode a batch of #{batch.size} records:"
puts format("%-34s %8s %10s %8s", "encoder", "cpu ms", "bytes", "ratio")
raw = batch.sum { |r| JSON.generate(r).bytesize + 1 }
puts format("%-34s %8.2f %10d %8s", "JSON.generate only", timed_ms { batch.each { |r| JSON.generate(r) } }, raw, "1.0x")
ms = timed_ms { encode.(batch) }
bytes = encode.(batch).bytesize
puts format("%-34s %8.2f %10d %7.1fx", "transport encode (json + gzip)", ms, bytes, raw.to_f / bytes)
[ 1, 3, 6, 9 ].each do |level|
  bytes = encode_at(batch, level).bytesize
  puts format("%-34s %8.2f %10d %7.1fx", "  gzip level #{level}", timed_ms { encode_at(batch, level) }, bytes, raw.to_f / bytes)
end
per_record = ms * 1000 / batch.size
puts format("=> %.1f µs of background CPU per record, %.0f µs per request's records", per_record, per_record * captured.size / requests)

GC.start
before = ObjectSpace.memsize_of_all
copies = captured.map { |r| r.transform_values { |v| v.dup rescue v } }
GC.start
per_rec = (ObjectSpace.memsize_of_all - before) / copies.size.to_f
puts format("\nheap per buffered record: ~%.0f bytes => a full buffer of %d records holds ~%.1f MB",
            per_rec, Lantern.config.buffer_size, per_rec * Lantern.config.buffer_size / 1_048_576)

work = -> { i = 0; s = +""; 200_000.times { i += 1; s << "x" if i % 1000 == 0 }; i }
def wall = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
5.times { work.call }
t0 = wall; 20.times { work.call }; alone = (wall - t0) / 20
stop = false
bg = Thread.new { encode.(batch) until stop }
sleep 0.05
t0 = wall; 20.times { work.call }; contended = (wall - t0) / 20
stop = true
bg.join
puts format("\nGVL: a pure-Ruby request-thread work unit takes %.2fms alone, %.2fms with the reporter thread encoding non-stop (%.0f%% slower)",
            alone, contended, (contended / alone - 1) * 100)
