# frozen_string_literal: true

require "spec_helper"

RSpec.describe "visit record", type: :request do
  def post_beacon(visits)
    post "/railwatch/beacon", params: { visits: visits }.to_json, headers: { "Content-Type" => "application/json" }
  end

  it "captures component, url, method, duration, status, partial, only, props_bytes, and user_agent from a beacon POST" do
    started_at = Time.now.to_f * 1000
    post_beacon([ {
      component: "Widgets/Index", url: "/widgets", method: "GET",
      started_at: started_at, duration_ms: 12.5,
      status: "200", partial: true, only: [ "widgets" ], props_bytes: 42
    } ])
    expect(response).to have_http_status(:no_content)

    visit = railwatch_records(:visit).sole
    expect(visit[:component]).to eq("Widgets/Index")
    expect(visit[:url]).to eq("/widgets")
    expect(visit[:method]).to eq("GET")
    expect(visit[:duration]).to eq(12_500) # duration_ms 12.5 -> microseconds
    expect(visit[:status]).to eq("200")
    expect(visit[:partial]).to be(true)
    expect(visit[:only]).to eq([ "widgets" ])
    expect(visit[:props_bytes]).to eq(42)
    expect(visit[:user_agent]).to be_a(String)
    expect(railwatch_records(:request)).to be_empty
  end

  describe "Core Web Vitals" do
    def post_vitals(vitals)
      post_beacon([ { component: "Widgets/Index", url: "/widgets", method: "GET",
                      started_at: Time.now.to_f * 1000, duration_ms: 1, status: "success" }.merge(vitals) ])
      railwatch_records(:visit).sole
    end

    it "captures lcp, cls, inp, and ttfb from the initial-load visit" do
      visit = post_vitals(lcp: 1234.6, cls: 0.05123, inp: 88.2, ttfb: 210.4)

      expect(visit[:lcp]).to eq(1235)
      expect(visit[:cls]).to eq(0.0512)
      expect(visit[:inp]).to eq(88)
      expect(visit[:ttfb]).to eq(210)
    end

    it "leaves each vital nil when the browser did not report it" do
      visit = post_vitals({})

      expect(visit.values_at(:lcp, :cls, :inp, :ttfb)).to eq([ nil, nil, nil, nil ])
    end

    it "clamps a negative millisecond metric to zero" do
      expect(post_vitals(lcp: -5)[:lcp]).to eq(0)
    end

    it "clamps a millisecond metric to two minutes" do
      expect(post_vitals(ttfb: 999_999_999)[:ttfb]).to eq(120_000)
    end

    it "clamps an absurd cls down to 100" do
      expect(post_vitals(cls: 500.5)[:cls]).to eq(100.0)
    end

    it "clamps a negative cls up to zero" do
      expect(post_vitals(cls: -1)[:cls]).to eq(0.0)
    end

    it "rounds a long cls float rather than storing full precision" do
      expect(post_vitals(cls: 0.123456789)[:cls]).to eq(0.1235)
    end
  end

  describe "TTFB phases" do
    def post_phases(phases)
      post_beacon([ { component: "Widgets/Index", url: "/sign_in", method: "GET",
                      started_at: Time.now.to_f * 1000, duration_ms: 1, status: "success", ttfb: 1200 }.merge(phases) ])
      railwatch_records(:visit).last
    end

    it "captures how the initial load's TTFB splits into redirects, connection and server" do
      visit = post_phases(redirect_ms: 1050.4, redirect_count: 2, connect_ms: 40.6, server_ms: 110.2)

      expect(visit.values_at(:redirect_ms, :redirect_count, :connect_ms, :server_ms)).to eq([ 1050, 2, 41, 110 ])
    end

    # A cross-origin hop makes the browser report 0 redirects; the client
    # leaves the count out then, and the time it still measured must land.
    it "keeps redirect time with no count, so a hidden redirect is not stored as none" do
      visit = post_phases(redirect_ms: 900)

      expect(visit[:redirect_ms]).to eq(900)
      expect(visit[:redirect_count]).to be_nil
    end

    it "leaves every phase nil for a visit that did not measure them" do
      visit = post_phases({})

      expect(visit.values_at(:redirect_ms, :redirect_count, :connect_ms, :server_ms)).to eq([ nil, nil, nil, nil ])
    end

    # The phases add up to ttfb. Clamping one of them, or ttfb past its cap,
    # would store a split that no longer does, so the split is dropped.
    it "drops the whole split rather than store one that no longer adds up to ttfb" do
      over = post_phases(ttfb: 121_000, redirect_ms: 119_000, connect_ms: 1_000, server_ms: 1_000)
      expect(over[:ttfb]).to eq(120_000)
      expect(over.values_at(:redirect_ms, :connect_ms, :server_ms)).to eq([ nil, nil, nil ])

      negative = post_phases(redirect_ms: -3, connect_ms: 3, server_ms: 1_200)
      expect(negative.values_at(:redirect_ms, :connect_ms, :server_ms)).to eq([ nil, nil, nil ])
    end

    it "stores a non-finite phase as unmeasured and keeps the rest of the beacon" do
      post_beacon([
        { component: "Bad", url: "/x", method: "GET", started_at: Time.now.to_f * 1000, duration_ms: 1,
          status: "success", redirect_ms: "1e309", server_ms: "-1e309", ttfb: "1e309" },
        { component: "Good", url: "/y", method: "GET", started_at: Time.now.to_f * 1000, duration_ms: 1,
          status: "success", redirect_ms: 12 }
      ])

      expect(response).to have_http_status(:no_content)
      bad, good = railwatch_records(:visit).last(2)
      expect(bad.values_at(:component, :redirect_ms, :server_ms, :ttfb)).to eq([ "Bad", nil, nil, nil ])
      expect(good.values_at(:component, :redirect_ms)).to eq([ "Good", 12 ])
    end

    it "clamps a redirect count to the browser's 20-hop limit" do
      expect(post_phases(redirect_count: 500)[:redirect_count]).to eq(20)
      expect(post_phases(redirect_count: -1)[:redirect_count]).to eq(0)
    end
  end

  it "caps at 50 visits from a single beacon POST even when more are sent" do
    visits = 60.times.map { |i| { component: "C#{i}", url: "/x", method: "GET", started_at: Time.now.to_f * 1000, duration_ms: 1, status: "200" } }
    post_beacon(visits)

    expect(railwatch_records(:visit).size).to eq(50)
  end

  it "ignores a visits value that is not an array and non-object entries within an array" do
    post "/railwatch/beacon", params: { visits: { component: "not-a-list" } }.to_json,
         headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:no_content)

    post_beacon([ "text", 42, nil, [ "nested" ], { component: "Valid", only: { not: "an array" } } ])

    expect(response).to have_http_status(:no_content)
    expect(railwatch_records(:visit).sole).to include(component: "Valid", only: [])
  end

  it "rejects a beacon body over 256 KiB before recording it" do
    post_beacon([ { component: "X", url: "x" * (Railwatch::BeaconController::MAX_REQUEST_BYTES + 1) } ])

    expect(response).to have_http_status(:content_too_large)
    expect(railwatch_records(:visit)).to be_empty
  end

  it "refuses a body whose Content-Length is over the limit without reading it" do
    body = StringIO.new("x" * (Railwatch::BeaconController::MAX_REQUEST_BYTES + 1))
    expect(body).not_to receive(:read)

    post "/railwatch/beacon", env: { "rack.input" => body, "CONTENT_LENGTH" => body.size.to_s,
                                     "CONTENT_TYPE" => "application/json" }

    expect(response).to have_http_status(:content_too_large)
    expect(railwatch_records(:visit)).to be_empty
  end

  # Rack::Test sets CONTENT_LENGTH from rack.input; a chunked request has none.
  def post_chunked(body)
    env = Rack::MockRequest.env_for("/railwatch/beacon", method: "POST", input: body,
                                                         "CONTENT_TYPE" => "application/json", "HTTP_TRANSFER_ENCODING" => "chunked")
    env.delete("CONTENT_LENGTH")
    Rails.application.call(env)
  end

  it "refuses a chunked body over the limit after reading only one byte past it" do
    limit = Railwatch::BeaconController::MAX_REQUEST_BYTES
    body = StringIO.new("x" * (limit * 4))

    status, = post_chunked(body)

    expect(status).to eq(413)
    expect(body.pos).to eq(limit + 1)
  end

  it "records a chunked body that arrives in short reads" do
    json = { visits: [ { component: "Trickled", url: "/t" } ] }.to_json
    body = StringIO.new(json)
    allow(body).to receive(:read).and_wrap_original { |m, n = nil, *rest| m.call(n && [ n, 7 ].min, *rest) }

    status, = post_chunked(body)

    expect(status).to eq(204)
    expect(railwatch_records(:visit).sole).to include(component: "Trickled")
  end

  it "records a chunked body under the limit" do
    body = StringIO.new({ visits: [ { component: "Chunked", url: "/c" } ] }.to_json)

    status, = post_chunked(body)

    expect(status).to eq(204)
    expect(railwatch_records(:visit).sole).to include(component: "Chunked")
  end

  it "does not answer 500 for a JSON body containing invalid UTF-8" do
    body = "{\"visits\":[{\"component\":\"bad\xFFvalue\"}]}".b
    post "/railwatch/beacon", params: body, headers: { "Content-Type" => "application/json" }

    expect(response.status).not_to be_between(500, 599)
    expect(railwatch_records(:visit)).to be_empty
  end

  it "threads Users.resolve_id's return value through as the visit's user field" do
    allow(Railwatch::Subscribers::Users).to receive(:resolve_id).and_return("42")
    post_beacon([ { component: "X", url: "/x", method: "GET", started_at: Time.now.to_f * 1000, duration_ms: 1, status: "200" } ])

    expect(railwatch_records(:visit).sole[:user]).to eq("42")
  end

  it "captures the current tenant" do
    tenant_record = Class.new { def self.current_tenant = "acme" }
    stub_const("TenantRecord", tenant_record)
    post_beacon([ { component: "X", url: "/x", method: "GET", started_at: Time.now.to_f * 1000, duration_ms: 1, status: "200" } ])

    expect(railwatch_records(:visit).sole[:tenant]).to eq("acme")
  end

  describe "session_id and tab_id" do
    def visit_with(fields)
      post_beacon([ { component: "X", url: "/x", method: "GET", started_at: Time.now.to_f * 1000, duration_ms: 1, status: "success" }.merge(fields) ])
      railwatch_records(:visit)
    end

    it "carries the session and tab each visit says it happened in" do
      visits = visit_with(session_id: "3f2a9c1e7b4d6a08", tab_id: "9e8d7c6b5a4f3e21")

      expect(visits.sole).to include(session_id: "3f2a9c1e7b4d6a08", tab_id: "9e8d7c6b5a4f3e21")
    end

    it "leaves both keys off a visit that carries neither" do
      visit = visit_with({}).sole

      expect(visit).not_to have_key(:session_id)
      expect(visit).not_to have_key(:tab_id)
    end

    it "drops an id that is too long, the wrong shape, or not a string, and still records the visit" do
      visit = visit_with(session_id: "a" * 65, tab_id: { "id" => "t1" }).sole
      expect(visit).not_to have_key(:session_id)
      expect(visit).not_to have_key(:tab_id)

      railwatch_transport.batches.clear
      visit = visit_with(session_id: "s 1", tab_id: "t-1_A").sole
      expect(visit).not_to have_key(:session_id)
      expect(visit[:tab_id]).to eq("t-1_A")
    end
  end

  it "responds 204 with nothing shipped when beacon_enabled is disabled" do
    Railwatch.config.beacon_enabled = false
    post_beacon([ { component: "X", url: "/x", method: "GET", started_at: Time.now.to_f * 1000, duration_ms: 1, status: "200" } ])

    expect(response).to have_http_status(:no_content)
    expect(railwatch_records(:visit)).to be_empty
  ensure
    Railwatch.config.beacon_enabled = true
  end
end
