# frozen_string_literal: true

require "spec_helper"

RSpec.describe "beacon rate limit", type: :request do
  def post_beacon(ip: "203.0.113.7")
    post "/lantern/beacon",
         params: { visits: [ { component: "Widgets/Index", url: "/widgets", method: "GET",
                               started_at: Time.now.to_f * 1000, duration_ms: 1, status: "200" } ] }.to_json,
         headers: { "Content-Type" => "application/json", "REMOTE_ADDR" => ip }
  end

  around do |example|
    original = Lantern.config.beacon_rate_limit
    Rails.cache.clear
    example.run
  ensure
    Lantern.config.beacon_rate_limit = original
    Rails.cache.clear
  end

  it "defaults to 120 beacons per client per minute, off with LANTERN_BEACON_RATE_LIMIT=0" do
    expect(Lantern::Configuration.new.beacon_rate_limit).to eq(120)
    ENV["LANTERN_BEACON_RATE_LIMIT"] = "0"
    expect(Lantern::Configuration.new.beacon_rate_limit).to eq(0)
  ensure
    ENV.delete("LANTERN_BEACON_RATE_LIMIT")
  end

  it "refuses the beacon past the limit with a Retry-After, and records nothing from it" do
    Lantern.config.beacon_rate_limit = 2

    2.times { post_beacon }
    expect(response).to have_http_status(:no_content)
    post_beacon
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Retry-After"]).to eq("60")
    expect(lantern_records(:visit).size).to eq(2)
  end

  it "counts each client address on its own" do
    Lantern.config.beacon_rate_limit = 1

    post_beacon(ip: "203.0.113.7")
    post_beacon(ip: "203.0.113.8")
    expect(response).to have_http_status(:no_content)
    post_beacon(ip: "203.0.113.7")
    expect(response).to have_http_status(:too_many_requests)
  end

  it "does not throttle when the limit is zero" do
    Lantern.config.beacon_rate_limit = 0

    3.times { post_beacon }
    expect(response).to have_http_status(:no_content)
    expect(lantern_records(:visit).size).to eq(3)
  end

  it "fails open on a cache store that cannot count" do
    Lantern.config.beacon_rate_limit = 1
    allow_any_instance_of(Lantern::BeaconController).to receive(:cache_store).and_return(ActiveSupport::Cache::NullStore.new)

    3.times { post_beacon }
    expect(response).to have_http_status(:no_content)
  end
end
