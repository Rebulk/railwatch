# frozen_string_literal: true

require "spec_helper"

RSpec.describe "browser exception record", type: :request do
  # Chrome's shape, with an app frame, a vendor chunk, a bare-path frame, a
  # third-party script, and the two lines that carry no location at all.
  STACK = <<~STACK
    TypeError: Cannot read properties of undefined (reading 'map')
        at IssueRow (http://www.example.com/assets/index-Bq1x9K.js:41:2210)
        at renderWithHooks (/assets/vendor-a1b2.js:12:3)
        at new Promise (<anonymous>)
        at track (https://cdn.other.test/widget.js:3:9)
  STACK

  def post_beacon(payload)
    post "/lantern/beacon", params: payload.to_json,
         headers: { "Content-Type" => "application/json", "User-Agent" => "Mozilla/5.0 (Macintosh) Chrome/141" }
  end

  def post_error(error)
    post_beacon(errors: [ { name: "TypeError", message: "boom", stack: STACK }.merge(error) ])
    lantern_records(:exception).sole
  end

  it "records a JavaScript error as an unhandled browser exception" do
    ex = post_error({})
    expect(response).to have_http_status(:no_content)

    expect(ex[:class]).to eq("TypeError")
    expect(ex[:message]).to eq("boom")
    expect(ex[:handled]).to be(false)
    expect(ex[:severity]).to eq("error")
    expect(ex[:source]).to eq("browser")
  end

  it "parses the browser's stack into the same frame shape a Ruby backtrace gets" do
    frames = post_error({})[:frames]

    expect(frames).to eq([
      { file: "assets/index-Bq1x9K.js", line: 41, column: 2210, function: "IssueRow", in_app: true },
      { file: "assets/vendor-a1b2.js", line: 12, column: 3, function: "renderWithHooks", in_app: false },
      { file: "https://cdn.other.test/widget.js", line: 3, column: 9, function: "track", in_app: false }
    ])
  end

  it "counts a same-origin script that is not vendored as the app's own code" do
    ex = post_error(stack: "at boot (http://www.example.com/app/frontend/entrypoints/app.tsx?t=1699:9:1)")

    expect(ex[:frames].sole).to include(file: "app/frontend/entrypoints/app.tsx", in_app: true)
  end

  it "counts a node_modules script on the app's own origin as not the app's code" do
    ex = post_error(stack: "at use (/node_modules/.vite/deps/react.js:5:5)")

    expect(ex[:frames].sole[:in_app]).to be(false)
  end

  it "files the error against the top in-app frame, as the Ruby side does" do
    ex = post_error({})

    expect(ex[:file]).to eq("assets/index-Bq1x9K.js")
    expect(ex[:line]).to eq(41)
  end

  it "groups on the default fingerprint -- class, top in-app frame, normalized message -- and says so" do
    ex = post_error(message: "Request to /orders/4821 failed")

    expect(ex[:fingerprint]).to eq([ "TypeError", "assets/index-Bq1x9K.js", "41", "Request to /orders/? failed" ])
    expect(ex[:fingerprint_source]).to eq("default")
    expect(ex[:_group]).to eq(Lantern::Record.group_hash(*ex[:fingerprint]))
  end

  it "groups two occurrences whose messages differ only in their variable data together" do
    post_beacon(errors: [ { name: "TypeError", message: "Order 1 is not payable", stack: STACK },
                          { name: "TypeError", message: "Order 22 is not payable", stack: STACK } ])

    expect(lantern_records(:exception).map { |ex| ex[:_group] }.uniq.size).to eq(1)
  end

  it "carries the page url, component, visit, session id, and user agent in the context" do
    post_beacon(session: { id: "sess123", started_at: Time.now.to_f * 1000 },
                errors: [ { name: "TypeError", message: "boom", stack: STACK, url: "/issues/7",
                            component: "issues/show", visit: "/issues/7?tab=events" } ])

    context = JSON.parse(lantern_records(:exception).sole[:context]).fetch("browser")
    expect(context["url"]).to eq("/issues/7")
    expect(context["component"]).to eq("issues/show")
    expect(context["visit"]).to eq("/issues/7?tab=events")
    expect(context["session"]).to eq("sess123")
    expect(context["user_agent"]).to include("Chrome/141")
  end

  it "timestamps the error at the moment the browser caught it, not the moment the beacon arrived" do
    caught_at = Time.now.to_f - 30
    ex = post_error(at: caught_at * 1000)

    expect(ex[:timestamp]).to be_within(0.01).of(caught_at)
  end

  it "truncates a runaway message and stack rather than shipping them whole" do
    ex = post_error(message: "x" * 5_000, stack: ("at f (/a.js:1:1)\n" * 2_000))

    expect(ex[:message].length).to eq(1024)
    expect(ex[:frames].size).to be <= 50
  end

  it "caps at 50 errors from a single beacon POST even when more are sent" do
    post_beacon(errors: 60.times.map { |i| { name: "TypeError", message: "boom #{i}", stack: STACK } })

    expect(lantern_records(:exception).size).to eq(50)
  end

  it "asks the app's beacon_user block who is behind the beacon, and describes them like any user" do
    session_user = Struct.new(:id, :name, :email).new(7, "Ada", "ada@example.com")
    Lantern.config.beacon_user { |request| request.headers["X-Session"] == "tok" ? session_user : nil }

    post "/lantern/beacon", params: { errors: [ { name: "TypeError", message: "boom", stack: STACK } ] }.to_json,
         headers: { "Content-Type" => "application/json", "X-Session" => "tok" }

    expect(lantern_records(:exception).sole[:user]).to eq("7")
    expect(lantern_records(:user).sole).to include(id: "7", name: "Ada", email: "ada@example.com")
  ensure
    Lantern.config.beacon_user
  end

  it "falls back to the request-style lookup when the beacon_user block returns nil" do
    Lantern.config.beacon_user { |_request| nil }
    allow(Lantern::Subscribers::Users).to receive(:resolve_id).and_return("42")

    expect(post_error({})[:user]).to eq("42")
  ensure
    Lantern.config.beacon_user
  end

  it "records no user when the beacon_user block raises" do
    Lantern.config.beacon_user { |_request| raise "session store down" }

    expect(post_error({})[:user]).to be_nil
  ensure
    Lantern.config.beacon_user
  end

  it "threads Users.resolve_id's return value through as the exception's user field" do
    allow(Lantern::Subscribers::Users).to receive(:resolve_id).and_return("42")

    expect(post_error({})[:user]).to eq("42")
  end

  it "captures the current tenant" do
    tenant_record = Class.new { def self.current_tenant = "acme" }
    stub_const("TenantRecord", tenant_record)

    expect(post_error({})[:tenant]).to eq("acme")
  end

  it "ships the error even when the beacon request itself was sampled out" do
    Lantern.config.sample = Lantern.config.sample.merge(requests: 0.0)
    post_error({})

    expect(lantern_records(:exception).size).to eq(1)
  end

  it "still records the beacon's visits alongside its errors" do
    post_beacon(visits: [ { component: "issues/show", url: "/issues/7", method: "GET",
                            started_at: Time.now.to_f * 1000, duration_ms: 1, status: "success" } ],
                errors: [ { name: "TypeError", message: "boom", stack: STACK } ])

    expect(lantern_records(:visit).size).to eq(1)
    expect(lantern_records(:exception).size).to eq(1)
  end

  describe "a payload the app did not write" do
    it "drops entries that are not error objects instead of answering 500" do
      post_beacon(errors: [ "oops", 42, [ "nested" ], nil, { name: "TypeError", message: "boom" } ])

      expect(response).to have_http_status(:no_content)
      expect(lantern_records(:exception).sole[:class]).to eq("TypeError")
    end

    it "drops an entry with no error name" do
      post_beacon(errors: [ {}, { name: "" }, { message: "nameless" } ])

      expect(response).to have_http_status(:no_content)
      expect(lantern_records(:exception)).to be_empty
    end

    it "ignores an errors key that is not a list" do
      post_beacon(errors: { name: "TypeError", message: "boom" })

      expect(response).to have_http_status(:no_content)
      expect(lantern_records(:exception)).to be_empty
    end

    it "records an error whose stack is missing or unparseable, with no frames" do
      ex = post_error(stack: nil)

      expect(ex[:frames]).to eq([])
      expect(ex[:file]).to be_nil
      expect(ex[:fingerprint]).to eq([ "TypeError", "", "", "boom" ])
    end
  end

  it "carries the deploy every other record carries, so a browser issue regresses with a release" do
    expect(post_error({})[:deploy]).to eq("abc123")
  end

  describe "breadcrumbs" do
    def post_crumbs(crumbs)
      post_beacon(errors: [ { name: "TypeError", message: "boom", stack: STACK, breadcrumbs: crumbs } ])
      JSON.parse(lantern_records(:exception).sole[:context]).fetch("browser")["breadcrumbs"]
    end

    it "stores the console, click, and navigation trail that led to the error" do
      at = Time.now.to_f * 1000
      trail = post_crumbs([ { at: at, kind: "navigate", text: "GET /issues/7" },
                            { at: at + 10, kind: "click", text: 'button#resolve "Resolve"' },
                            { at: at + 20, kind: "console", text: "error: boom" } ])

      expect(trail.map { |c| c["kind"] }).to eq(%w[navigate click console])
      expect(trail.last["text"]).to eq("error: boom")
      expect(trail.first["at"]).to be_within(1).of(at)
    end

    it "keeps at most twenty crumbs and truncates a runaway one" do
      trail = post_crumbs(30.times.map { |i| { at: 0, kind: "click", text: "b#{i}" * 400 } })

      expect(trail.size).to eq(20)
      expect(trail.first["text"].length).to eq(500)
    end

    it "drops crumbs of an unknown kind, with no text, or of the wrong shape entirely" do
      trail = post_crumbs([ { at: 0, kind: "keystroke", text: "hunter2" }, { at: 0, kind: "click", text: "" },
                            "not a crumb", { at: 0, kind: "click", text: "button" } ])

      expect(trail).to eq([ { "at" => 0.0, "kind" => "click", "text" => "button" } ])
    end

    it "leaves breadcrumbs out entirely when the client sent none" do
      post_beacon(errors: [ { name: "TypeError", message: "boom", breadcrumbs: "nonsense" } ])

      expect(JSON.parse(lantern_records(:exception).sole[:context]).fetch("browser")).not_to have_key("breadcrumbs")
    end
  end

  describe "context from reportError" do
    it "merges what the app passed alongside the browser's own fields" do
      post_beacon(errors: [ { name: "TypeError", message: "boom",
                              context: { componentStack: "\n    at MapPanel\n    at SiteEdit" } } ])

      context = JSON.parse(lantern_records(:exception).sole[:context])
      expect(context["componentStack"]).to include("at MapPanel")
      expect(context).to have_key("browser")
    end

    it "flattens each value and keeps at most twenty keys, whatever the app sent" do
      post_beacon(errors: [ { name: "TypeError", message: "boom",
                              context: 30.times.to_h { |i| [ "k#{i}", { nested: [ 1, 2 ] } ] } } ])

      context = JSON.parse(lantern_records(:exception).sole[:context]).except("browser")
      expect(context.size).to eq(20)
      expect(context.values).to all(be_a(String))
    end

    it "ignores a context that is not an object" do
      post_beacon(errors: [ { name: "TypeError", message: "boom", context: [ "nope" ] } ])

      expect(response).to have_http_status(:no_content)
      expect(JSON.parse(lantern_records(:exception).sole[:context]).keys).to eq([ "browser" ])
    end
  end

  describe "the tenant hint" do
    it "stamps the tenant the client reported, since the beacon is outside the app's tenant scoping" do
      post_beacon(tenant: "acme", errors: [ { name: "TypeError", message: "boom" } ])

      expect(lantern_records(:exception).sole[:tenant]).to eq("acme")
      expect(lantern_records(:session)).to be_empty
    end

    it "prefers the tenant the server resolved for itself over the client's hint" do
      tenant_record = Class.new { def self.current_tenant = "resolved" }
      stub_const("TenantRecord", tenant_record)
      post_beacon(tenant: "spoofed", errors: [ { name: "TypeError", message: "boom" } ])

      expect(lantern_records(:exception).sole[:tenant]).to eq("resolved")
    end

    it "ignores a hint that is not a string" do
      post_beacon(tenant: { slug: "acme" }, errors: [ { name: "TypeError", message: "boom" } ])

      expect(response).to have_http_status(:no_content)
      expect(lantern_records(:exception).sole[:tenant]).to be_nil
    end

    it "stamps the hint on the beacon's visits too" do
      post_beacon(tenant: "acme", visits: [ { component: "X", url: "/x", method: "GET",
                                              started_at: Time.now.to_f * 1000, duration_ms: 1, status: "success" } ])

      expect(lantern_records(:visit).sole[:tenant]).to eq("acme")
    end
  end

  it "records nothing when beacon_enabled is disabled" do
    Lantern.config.beacon_enabled = false
    post_beacon(errors: [ { name: "TypeError", message: "boom", stack: STACK } ])

    expect(response).to have_http_status(:no_content)
    expect(lantern_records(:exception)).to be_empty
  ensure
    Lantern.config.beacon_enabled = true
  end
end
