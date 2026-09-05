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

  it "strips every query parameter from the request URL without changing route grouping" do
    get "/widgets?password=secret&token=reset-token&code=oauth-code&X-Amz-Signature=signed-secret"
    get "/widgets?password=other&token=other&code=other&X-Amz-Signature=other"

    requests = lantern_records(:request)
    expect(requests.map { |request| request[:url] }).to eq([ "http://www.example.com/widgets" ] * 2)
    expect(requests.map { |request| request[:path] }).to eq([ "/widgets" ] * 2)
    expect(requests.map { |request| request[:_group] }.uniq).to eq([ Lantern::Record.group_hash("GET", "/widgets(.:format)") ])
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

  it "strips credentials, query, and fragment from the recorded redirect target without touching the Location header" do
    get "/redirected_with_credentials"

    req = lantern_records(:request).sole
    expect(response.location).to include("api-key:api-secret@", "password=secret", "token=reset-token", "code=oauth-code", "X-Amz-Signature=signed-secret", "#private-fragment")
    expect(req[:redirect_to]).to eq("http://www.example.com/widgets")
  end

  it "strips a fragment even when a URL has no query string" do
    expect(Lantern::Record.url_without_sensitive_components("https://example.test/widgets#token=secret", limit: 2048))
      .to eq("https://example.test/widgets")
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

  describe "queue_time" do
    # 50ms of proxy queueing (50_000 microseconds once recorded), expressed
    # in each format a proxy might stamp it. The upper bound catches a
    # misread unit: seconds or microseconds read as milliseconds land
    # decades away, not a millisecond either side.
    let(:queued_at) { Time.now.to_f - 0.05 }

    def queue_time_for(header, name: "X-Request-Start")
      get "/widgets", headers: { name => header }
      lantern_records(:request).sole[:queue_time]
    end

    it "is nil when no proxy stamped the request" do
      get "/widgets"

      expect(lantern_records(:request).sole[:queue_time]).to be_nil
    end

    it "reads t= milliseconds (nginx, Heroku)" do
      expect(queue_time_for("t=#{(queued_at * 1_000).round}")).to be_between(49_000, 1_000_000)
    end

    it "reads t= microseconds (HAProxy 1.9+)" do
      expect(queue_time_for("t=#{(queued_at * 1_000_000).round}")).to be_between(49_000, 1_000_000)
    end

    it "reads t= seconds with a fractional part" do
      expect(queue_time_for("t=#{format('%.3f', queued_at)}")).to be_between(49_000, 1_000_000)
    end

    it "reads a bare millisecond integer, with no t= prefix" do
      expect(queue_time_for((queued_at * 1_000).round.to_s)).to be_between(49_000, 1_000_000)
    end

    it "reads X-Queue-Start when X-Request-Start is absent" do
      expect(queue_time_for("t=#{(queued_at * 1_000).round}", name: "X-Queue-Start")).to be_between(49_000, 1_000_000)
    end


    it "drops a stamp more than 60 seconds old as clock skew, not a real wait" do
      expect(queue_time_for("t=#{((Time.now.to_f - 300) * 1_000).round}")).to be_nil
    end

    it "clamps a stamp from a proxy clock running ahead to zero" do
      expect(queue_time_for("t=#{((Time.now.to_f + 10) * 1_000).round}")).to eq(0)
    end

    it "is nil for an unparseable stamp" do
      expect(queue_time_for("t=nonsense")).to be_nil
    end
  end
end
