# frozen_string_literal: true

# Decomposes the per-query cost. First how much of it is Rails' own
# notification dispatch (per subscriber, by subscriber style), then what
# Railwatch's SQL subscribers add in each execution state, then the pieces of
# the subscriber body in isolation. Also shows what Rails' SQL log
# formatting costs once something puts Rails.logger.debug? on.
#
#   bundle exec ruby bench/query_path.rb
require_relative "support"

conn = ActiveRecord::Base.lease_connection
sql = 'SELECT "widgets".* FROM "widgets" WHERE "widgets"."id" = ? LIMIT ?'
payload = { sql: sql, name: "Widget Load", binds: [], type_casted_binds: [], connection: conn, row_count: 1, cached: false, async: false, transaction: nil }
notify = -> { ActiveSupport::Notifications.instrument("sql.active_record", payload) { 1 } }

rows = []
sql_subs = RAILWATCH_SUBSCRIPTIONS.select { |p, _, _| p == "sql.active_record" }
sql_subs.each { |_, s, _| ActiveSupport::Notifications.unsubscribe(s) }

rows << [ "sql.active_record instrument, Rails' AR LogSubscriber only (Railwatch unsubscribed)", per_call(&notify) ]
empties = []
(1..3).each do |n|
  empties << ActiveSupport::Notifications.subscribe("sql.active_record") { |_event| nil }
  rows << [ "  + #{n} empty Event subscriber(s) (block |event|)", per_call(&notify) ]
end
empties.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
timed = ActiveSupport::Notifications.subscribe("sql.active_record") { |*_args| nil }
rows << [ "  + 1 empty timed subscriber (block |*args|) instead", per_call(&notify) ]
ActiveSupport::Notifications.unsubscribe(timed)
mono = ActiveSupport::Notifications.monotonic_subscribe("sql.active_record") { |*_args| nil }
rows << [ "  + 1 empty monotonic_subscribe (|*args|) instead", per_call(&notify) ]
ActiveSupport::Notifications.unsubscribe(mono)

Rails.logger.stop_broadcasting_to(CAPTURE)
rows << [ "  Railwatch log Capture detached (Rails.logger.debug? => #{Rails.logger.debug?})", per_call(&notify) ]
Rails.logger.broadcast_to(CAPTURE)
rows << [ "  Capture attached at its level (Rails.logger.debug? => #{Rails.logger.debug?})", per_call(&notify) ]
# The Capture starts at config.log_level and is an ordinary Logger from
# then on, so this is what an app running its logger at DEBUG pays per
# query with Railwatch attached.
CAPTURE.level = ::Logger::DEBUG
rows << [ "  Capture at DEBUG (Rails.logger.debug? => #{Rails.logger.debug?}): AR formats every SQL line", per_call(&notify) ]
CAPTURE.level = ::Logger::INFO

sql_subs.each { |p, s, how| ActiveSupport::Notifications.public_send(how, p, s.instance_variable_get(:@delegate)) }
rows << [ "Railwatch sql subscribers, no execution (query outside a request/job): builds and drops", per_call(&notify) ]
exe = Railwatch.start_execution(source: :request, sample_kind: :requests, preview: "bench")
exe.enter_stage(:action)
rows << [ "  in a sampled-in execution: builds and buffers", per_call { notify.call; exe.records.clear } ]
exe.sampled = false
rows << [ "  in a sampled-out execution: counts only", per_call(&notify) ]
exe.sampled = true

adapter, db, = Railwatch::Subscribers::Queries.connection_info(conn)
group, = Railwatch::SqlNormalizer.group_and_normalized(sql, adapter: adapter, connection_name: db)
rows << [ "    SqlNormalizer cache hit", per_call { Railwatch::SqlNormalizer.group_and_normalized(sql, adapter: adapter, connection_name: db) } ]
rows << [ "    connection_info memo hit", per_call { Railwatch::Subscribers::Queries.connection_info(conn) } ]
rows << [ "    source_for cache hit", per_call { Railwatch::Subscribers::Queries.source_for(group, false) } ]
rows << [ "    Backtrace.caller_location (n+1 record, slow query, first sight of a group)", per_call(2_000) { Railwatch::Backtrace.caller_location(skip: 1) } ]
rows << [ "    exe.envelope memo hit", per_call { exe.envelope } ]
rows << [ "    Record.group_hash (MD5)", per_call { Railwatch::Record.group_hash("MemoryStore", "widgets/?") } ]
rows << [ "    Context.serialized (per log line, per parent, per exception)", per_call { Railwatch::Context.serialized } ]
rows << [ "    Execution.new (sampled in)", per_call(5_000) { Railwatch::Execution.new(source: :request, sampled: true) } ]

print_rows(rows, label_width: 92)
