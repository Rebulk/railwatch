# frozen_string_literal: true

require "spec_helper"

RSpec.describe "visit record", type: :request do
  def post_beacon(visits)
    post "/lantern/beacon", params: { visits: visits }.to_json, headers: { "Content-Type" => "application/json" }
  end

  it "captures component, url, method, duration, status, partial, only, props_bytes, and user_agent from a beacon POST" do
    started_at = Time.now.to_f * 1000
    post_beacon([ {
      component: "Widgets/Index", url: "/widgets", method: "GET",
      started_at: started_at, duration_ms: 12.5,
      status: "200", partial: true, only: [ "widgets" ], props_bytes: 42
    } ])
    expect(response).to have_http_status(:no_content)

    visit = lantern_records(:visit).sole
    expect(visit[:component]).to eq("Widgets/Index")
    expect(visit[:url]).to eq("/widgets")
    expect(visit[:method]).to eq("GET")
    expect(visit[:duration]).to eq(12_500) # duration_ms 12.5 -> microseconds
    expect(visit[:status]).to eq("200")
    expect(visit[:partial]).to be(true)
    expect(visit[:only]).to eq([ "widgets" ])
    expect(visit[:props_bytes]).to eq(42)
    expect(visit[:user_agent]).to be_a(String)
    expect(lantern_records(:request)).to be_empty
  end

  describe "Core Web Vitals" do
    def post_vitals(vitals)
      post_beacon([ { component: "Widgets/Index", url: "/widgets", method: "GET",
                      started_at: Time.now.to_f * 1000, duration_ms: 1, status: "success" }.merge(vitals) ])
      lantern_records(:visit).sole
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

  it "caps at 50 visits from a single beacon POST even when more are sent" do
    visits = 60.times.map { |i| { component: "C#{i}", url: "/x", method: "GET", started_at: Time.now.to_f * 1000, duration_ms: 1, status: "200" } }
    post_beacon(visits)

    expect(lantern_records(:visit).size).to eq(50)
  end

  it "threads Users.resolve_id's return value through as the visit's user field" do
    allow(Lantern::Subscribers::Users).to receive(:resolve_id).and_return("42")
    post_beacon([ { component: "X", url: "/x", method: "GET", started_at: Time.now.to_f * 1000, duration_ms: 1, status: "200" } ])

    expect(lantern_records(:visit).sole[:user]).to eq("42")
  end

  it "captures the current tenant" do
    tenant_record = Class.new { def self.current_tenant = "acme" }
    stub_const("TenantRecord", tenant_record)
    post_beacon([ { component: "X", url: "/x", method: "GET", started_at: Time.now.to_f * 1000, duration_ms: 1, status: "200" } ])

    expect(lantern_records(:visit).sole[:tenant]).to eq("acme")
  end

  it "responds 204 with nothing shipped when beacon_enabled is disabled" do
    Lantern.config.beacon_enabled = false
    post_beacon([ { component: "X", url: "/x", method: "GET", started_at: Time.now.to_f * 1000, duration_ms: 1, status: "200" } ])

    expect(response).to have_http_status(:no_content)
    expect(lantern_records(:visit)).to be_empty
  ensure
    Lantern.config.beacon_enabled = true
  end
end
