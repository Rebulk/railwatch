# frozen_string_literal: true

# How fast the export queue drains a backlog, per delivery and overall.
#
# Seeds the telemetry database the way a long-running production queue looks
# -- DONE rows (default 300,000; prune! keeps them for eight days) plus a
# backlog of one-record pending deliveries (default 2,000) -- then drives the
# sender's own loop (Export::Sender.drain_one) against a stub receiver on a
# real local socket, which answers like railwatch-cloud after SERVER_MS of
# processing. Nothing is mocked between the queue and the socket.
#
#   bundle exec ruby bench/export_drain.rb
#   DONE_ROWS=300000 BACKLOG=2000 SERVER_MS=5 HANDSHAKE_MS=0 bundle exec ruby bench/export_drain.rb
#
# HANDSHAKE_MS delays the receiver's accept, to stand in for the TCP+TLS
# handshake a new connection costs over a real network (~240 ms measured from
# a production box); locally a connect is otherwise free.
# Its own database files: the seed is hundreds of thousands of rows, and the
# test suite shares the default ones (the telemetry database is not rolled
# back between examples).
ENV["TEST_ENV_NUMBER"] ||= "_export_drain"
require_relative "support"
require "socket"
require "benchmark"

DONE_ROWS = Integer(ENV.fetch("DONE_ROWS", 300_000))
BACKLOG = Integer(ENV.fetch("BACKLOG", 2_000))
SERVER_MS = Float(ENV.fetch("SERVER_MS", 5))
HANDSHAKE_MS = Float(ENV.fetch("HANDSHAKE_MS", 0))

%w[railwatch railwatch_telemetry].each do |name|
  db_config = ActiveRecord::Base.configurations.configs_for(env_name: "test", name: name)
  ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(db_config) do |connection|
    connection.pool.migration_context.migrate
  end
end

# The stub receiver: HTTP/1.1 keep-alive, one thread per connection.
server = TCPServer.new("127.0.0.1", 0)
connections = 0
requests = 0
Thread.new do
  loop do
    sock = server.accept
    sleep(HANDSHAKE_MS / 1000.0) if HANDSHAKE_MS.positive?
    connections += 1
    Thread.new(sock) do |conn|
      loop do
        head = +""
        while (line = conn.gets) && line != "\r\n"
          head << line
        end
        break if line.nil?

        body = conn.read(head[/content-length: (\d+)/i, 1].to_i)
        records = Zlib.gunzip(body).lines.size
        sleep(SERVER_MS / 1000.0)
        requests += 1
        reply = JSON.generate(disposition: "committed", accepted: records, rejected: 0)
        conn.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{reply.bytesize}\r\n\r\n#{reply}")
      end
    rescue IOError, SystemCallError
      nil
    ensure
      conn.close
    end
  end
end

config = Railwatch.config
config.transport = :local
config.allow_http = true if config.respond_to?(:allow_http=)
config.export_enabled = true
config.export_url = "http://127.0.0.1:#{server.addr[1]}/ingest"
config.export_token = "rw_bench"

env = Railwatch::Environment.current
outbox = Railwatch::Export::Outbox.new(config, env)
record = lambda do |i|
  { "v" => 1, "t" => "request", "timestamp" => Time.now.to_f, "method" => "GET", "route" => "/widgets/#{i}",
    "controller" => "widgets", "action" => "index", "status_code" => 200, "duration" => 12_000,
    "stages" => { "action" => 10_000 }, "counters" => { "queries" => 1 },
    "execution_id" => SecureRandom.uuid, "_group" => Digest::MD5.hexdigest("req") }
end

env.with_telemetry do
  Railwatch::Telemetry::ExportDelivery.delete_all
  Railwatch::Telemetry::ExportDestination.delete_all
  dest = outbox.binding_row
  now = Time.current
  DONE_ROWS.times.each_slice(10_000) do |slice|
    Railwatch::Telemetry::ExportDelivery.insert_all(slice.map do |i|
      { export_destination_id: dest.id, delivery_id: SecureRandom.uuid, selection_key: "done:#{i}",
        body_sha256: "0" * 64, metadata_sha256: "0" * 64, body_bytes: 640, ndjson_bytes: 900, record_count: 1,
        wire_metadata: {}, state: "done", disposition: "acked", enqueued_at: now, expires_at: now,
        next_attempt_at: now, finished_at: now, created_at: now, updated_at: now }
    end)
  end
  encoder = Railwatch::Transport::WireEncoder.new(batch_bytes: config.batch_bytes)
  Railwatch::Telemetry::ExportDelivery.transaction do
    BACKLOG.times do |i|
      selections = Railwatch::Export::Policy::Everything.prepare(records: [ record.(i) ], encoder: encoder,
                                                                source_batch_id: SecureRandom.uuid)
      outbox.enqueue!(selections, now: now)
    end
  end
end

Railwatch::Export::Sender.instance_variable_set(:@owner, SecureRandom.uuid)
Railwatch::Export::Sender.instance_variable_set(:@client, nil)

claim_ms = []
if Railwatch::Export::Outbox.method_defined?(:claim!)
  orig = Railwatch::Export::Outbox.instance_method(:claim!)
  Railwatch::Export::Outbox.define_method(:claim!) do |**kw|
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    orig.bind_call(self, **kw).tap { claim_ms << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000 }
  end
end

sent = 0
elapsed = Benchmark.realtime do
  sent += 1 while Railwatch::Export::Sender.drain_one
end

pending = env.with_telemetry { Railwatch::Telemetry::ExportDelivery.where.not(state: "done").count }
acked_records = env.with_telemetry do
  Railwatch::Telemetry::ExportDelivery.where(disposition: "acked").where("selection_key NOT LIKE 'done:%'").sum(:record_count)
end
claim_ms.sort!
p50 = claim_ms[claim_ms.size / 2]
puts format("backlog %d one-record deliveries over %d done rows, server %.0f ms, handshake %.0f ms",
            BACKLOG, DONE_ROWS, SERVER_MS, HANDSHAKE_MS)
puts format("  %d requests, %d connections, %.2f s total: %.1f ms per request, %.0f deliveries/min drained",
            requests, connections, elapsed, elapsed * 1000 / [ requests, 1 ].max, BACKLOG / elapsed * 60)
puts format("  claim! p50 %.2f ms, max %.2f ms; records acked %d of %d; still pending %d",
            p50 || 0, claim_ms.last || 0, acked_records, BACKLOG, pending)
