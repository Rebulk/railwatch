# frozen_string_literal: true

# Decomposes the fixed per-request cost: the pieces the middleware and the
# request subscribers run once per request, measured in isolation. Indented
# rows are parts of the row above them.
#
#   bundle exec ruby bench/request_path.rb
require_relative "support"

stub_reporter_writes!

env = Rack::MockRequest.env_for("/widgets?x=1", "HTTP_USER_AGENT" => "bench/1.0", "HTTP_ACCEPT" => "text/html", "HTTP_COOKIE" => "a=b", "HTTP_X_FORWARDED_FOR" => "10.0.0.1", "HTTP_ACCEPT_ENCODING" => "gzip", "HTTP_ACCEPT_LANGUAGE" => "en", "HTTP_HOST" => "example.org")
mw = Nightrail::Middleware::Request.new(->(_e) { [ 200, { "Content-Length" => "2" }, [ "ok" ] ] })
Current.user = User.first

rows = []
rows << [ "middleware call (whole request path, app is a no-op lambda)", per_call { mw.call(env.dup) } ]
rows << [ "  Nightrail.start_execution", per_call { Nightrail.start_execution(source: :request, sample_kind: :requests); Nightrail::Current.clear } ]
rows << [ "    Execution.new", per_call { Nightrail::Execution.new(source: :request, sampled: true) } ]
rows << [ "      SecureRandom.uuid x2", per_call { SecureRandom.uuid; SecureRandom.uuid } ]
rows << [ "      COUNTERS.to_h { [c, 0] }", per_call { Nightrail::Execution::COUNTERS.to_h { |c| [ c, 0 ] } } ]
rows << [ "    Sampler.decide", per_call { Nightrail::Sampler.decide(:requests) } ]
rows << [ "    Context.current_tenant", per_call { Nightrail::Context.current_tenant } ]
exe = Nightrail.start_execution(source: :request, sample_kind: :requests)
exe.enter_stage(:action)
rows << [ "  parent_fields (builds the request record's fields)", per_call { mw.send(:parent_fields, env, exe, 200, { "Content-Length" => "2" }) } ]
rows << [ "    ActionDispatch::Request.new + original_url + remote_ip + format", per_call { r = ActionDispatch::Request.new(env); r.original_url; r.remote_ip; r.format; r.user_agent } ]
rows << [ "    request_headers (env walk + redaction)", per_call { mw.send(:request_headers, env) } ]
rows << [ "    Users.resolve_id (Current.user set)", per_call { Nightrail::Subscribers::Users.resolve_id(env) } ]
rows << [ "    Record.group_hash(method, pattern)", per_call { Nightrail::Record.group_hash("GET", "/widgets") } ]
rows << [ "    ignored_request?", per_call { mw.send(:ignored_request?, env) } ]
rows << [ "  build_parent (Record.build + Context.serialized + counters)", per_call { Nightrail.build_parent(:request, exe, group: "g", method: "GET") } ]
rows << [ "    Context.serialized", per_call { Nightrail::Context.serialized } ]
rows << [ "    exe.capture_memory", per_call { exe.capture_memory } ]
rows << [ "  Sessions.touch (user resolved, no cookie)", per_call { Nightrail::Sessions.touch(exe, env, 200) } ]
rows << [ "  Logs::Capture x3 framework lines (Started/Processing/Completed)", per_call {
  Nightrail::Subscribers::Logs.write("info", "Started GET \"/widgets\" for 127.0.0.1 at 2026-09-05")
  Nightrail::Subscribers::Logs.write("info", "Processing by WidgetsController#index as HTML")
  Nightrail::Subscribers::Logs.write("info", "Completed 200 OK in 3ms (Views: 0.2ms | ActiveRecord: 0.5ms)")
} ]
rows << [ "  Logs::Capture x1 app line (recorded)", per_call { Nightrail::Subscribers::Logs.write("info", "listed 3 widgets"); exe.records.clear } ]
rows << [ "  start_processing subscriber work (route_pattern, preview)", per_call {
  req = ActionDispatch::Request.new(env)
  Nightrail::Subscribers::Requests.route_pattern(req)
  exe.preview = "WidgetsController#index"
} ]

print_rows(rows)
