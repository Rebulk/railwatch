# frozen_string_literal: true

require "spec_helper"

RSpec.describe "beacon rate limit", type: :request do
  def post_beacon(ip: "203.0.113.7")
    post "/nightrail/beacon",
         params: { visits: [ { component: "Widgets/Index", url: "/widgets", method: "GET",
                               started_at: Time.now.to_f * 1000, duration_ms: 1, status: "200" } ] }.to_json,
         headers: { "Content-Type" => "application/json", "REMOTE_ADDR" => ip }
  end

  around do |example|
    original = Nightrail.config.beacon_rate_limit
    Rails.cache.clear
    example.run
  ensure
    Nightrail.config.beacon_rate_limit = original
    Rails.cache.clear
  end

  it "defaults to 120 beacons per client per minute; 0 turns it off and a negative value counts as 0" do
    original = ENV["NIGHTRAIL_BEACON_RATE_LIMIT"]
    ENV.delete("NIGHTRAIL_BEACON_RATE_LIMIT")
    expect(Nightrail::Configuration.new.beacon_rate_limit).to eq(120)
    ENV["NIGHTRAIL_BEACON_RATE_LIMIT"] = "0"
    expect(Nightrail::Configuration.new.beacon_rate_limit).to eq(0)
    ENV["NIGHTRAIL_BEACON_RATE_LIMIT"] = "-5"
    expect(Nightrail::Configuration.new.beacon_rate_limit).to eq(0)
  ensure
    original ? ENV["NIGHTRAIL_BEACON_RATE_LIMIT"] = original : ENV.delete("NIGHTRAIL_BEACON_RATE_LIMIT")
  end

  it "answers 204 rather than 429 when the beacon is disabled, whatever the client has sent before" do
    Nightrail.config.beacon_rate_limit = 1
    Nightrail.config.beacon_enabled = false

    3.times { post_beacon }
    expect(response).to have_http_status(:no_content)
    expect(nightrail_records(:visit)).to be_empty
  ensure
    Nightrail.config.beacon_enabled = true
  end

  it "refuses the beacon past the limit with a Retry-After, and records nothing from it" do
    Nightrail.config.beacon_rate_limit = 2

    2.times { post_beacon }
    expect(response).to have_http_status(:no_content)
    post_beacon
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Retry-After"]).to eq("60")
    expect(nightrail_records(:visit).size).to eq(2)
  end

  it "counts each client address on its own" do
    Nightrail.config.beacon_rate_limit = 1

    post_beacon(ip: "203.0.113.7")
    post_beacon(ip: "203.0.113.8")
    expect(response).to have_http_status(:no_content)
    post_beacon(ip: "203.0.113.7")
    expect(response).to have_http_status(:too_many_requests)
  end

  it "does not throttle when the limit is zero" do
    Nightrail.config.beacon_rate_limit = 0

    3.times { post_beacon }
    expect(response).to have_http_status(:no_content)
    expect(nightrail_records(:visit).size).to eq(3)
  end

  it "fails open on a cache store that cannot count" do
    Nightrail.config.beacon_rate_limit = 1
    allow_any_instance_of(Nightrail::BeaconController).to receive(:cache_store).and_return(ActiveSupport::Cache::NullStore.new)

    3.times { post_beacon }
    expect(response).to have_http_status(:no_content)
  end
end
