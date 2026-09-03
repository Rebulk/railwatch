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
