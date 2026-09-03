# frozen_string_literal: true

require "spec_helper"

# Fields already covered field-by-field in spec/requests/requests_spec.rb
# (owned by another engineer) are not re-asserted here: method/route/
# controller/action/status_code, stages, counters, user, duration, headers,
# queries/execution_id linkage, N+1, exceptions, handled errors, cache
# events, outgoing_request, mail, enqueued jobs, the core Inertia fields
# (component/version/partial_only/props_bytes), SSR timing, sampling, and
# uploaded files. This file covers the remaining request record fields.
RSpec.describe "request record", type: :request do
  it "captures format, ip, and zero-byte request/response sizes for a bodyless GET" do
    get "/widgets"

    req = lantern_records(:request).sole
    expect(req[:format]).to eq("html")
    expect(req[:ip]).to eq("127.0.0.1")
    expect(req[:request_size]).to eq(0)
    expect(req[:response_size]).to eq(0)
  end

  it "groups requests by an MD5 hash of the HTTP method and route pattern" do
    get "/widgets"

    req = lantern_records(:request).sole
    expect(req[:_group]).to eq(Lantern::Record.group_hash("GET", "/widgets(.:format)"))
  end

  it "captures view_runtime and db_runtime from the controller's process_action payload" do
    3.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) }
    get "/many"

    req = lantern_records(:request).sole
    expect(req[:view_runtime]).to be_a(Float).and be > 0
    expect(req[:db_runtime]).to be_a(Float).and be > 0
  end

  it "captures the redirect target when the controller redirects" do
    get "/redirected"

    req = lantern_records(:request).sole
    expect(req[:redirect_to]).to eq("http://www.example.com/widgets")
    expect(req[:status_code]).to eq(302)
  end

  it "captures the halting filter's name when a before_action halts the chain" do
    get "/halted"

    req = lantern_records(:request).sole
    expect(req[:halted_callback]).to eq("halt_it")
    expect(req[:status_code]).to eq(403)
  end

  it "captures unpermitted parameter keys reported by strong parameters" do
    get "/unpermitted", params: { allowed: "x", extra: "y" }

    req = lantern_records(:request).sole
    expect(req[:unpermitted_parameters]).to eq([ "extra" ])
  end

  it "captures rate limit details once the native rate_limit threshold is exceeded" do
    get "/rate_limited"
    get "/rate_limited"

    reqs = lantern_records(:request)
    expect(reqs.first[:rate_limited]).to be_nil
    expect(reqs.first[:status_code]).to eq(200)
    expect(reqs.last[:rate_limited]).to include(count: 2, to: 1)
    expect(reqs.last[:status_code]).to eq(429)
  end

  it "carries the Inertia partial-render component and except headers" do
    get "/inertia", headers: { "X-Inertia" => "true", "X-Inertia-Partial-Component" => "widgets/index", "X-Inertia-Partial-Except" => "b" }

    req = lantern_records(:request).sole
    expect(req[:inertia]).to include(partial_component: "widgets/index", partial_except: "b")
  end

  it "captures redacted request params as the payload once an exception occurs, when capture_request_payload is enabled" do
    Lantern.config.capture_request_payload = true
    get "/boom", params: { x: "1", password: "secret" }

    req = lantern_records(:request).sole
    expect(req[:payload]).to eq({ "x" => "1", "password" => "[FILTERED]" })
  ensure
    Lantern.config.capture_request_payload = false
  end

  it "leaves payload nil when capture_request_payload is disabled, even on an exception" do
    get "/boom", params: { x: "1" }

    req = lantern_records(:request).sole
    expect(req[:payload]).to be_nil
  end
end
