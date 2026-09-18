# frozen_string_literal: true

require "spec_helper"

RSpec.describe "beacon rate limit", type: :request do
  def post_beacon(ip: "203.0.113.7")
    post "/railwatch/beacon",
         params: { visits: [ { component: "Widgets/Index", url: "/widgets", method: "GET",
                               started_at: Time.now.to_f * 1000, duration_ms: 1, status: "200" } ] }.to_json,
         headers: { "Content-Type" => "application/json", "REMOTE_ADDR" => ip }
  end

  around do |example|
    original = Railwatch.config.beacon_rate_limit
    Rails.cache.clear
    example.run
  ensure
    Railwatch.config.beacon_rate_limit = original
    Rails.cache.clear
  end

  it "defaults to 120 beacons per client per minute; 0 turns it off and a negative value counts as 0" do
    original = ENV["RAILWATCH_BEACON_RATE_LIMIT"]
    ENV.delete("RAILWATCH_BEACON_RATE_LIMIT")
    expect(Railwatch::Configuration.new.beacon_rate_limit).to eq(120)
    ENV["RAILWATCH_BEACON_RATE_LIMIT"] = "0"
    expect(Railwatch::Configuration.new.beacon_rate_limit).to eq(0)
    ENV["RAILWATCH_BEACON_RATE_LIMIT"] = "-5"
    expect(Railwatch::Configuration.new.beacon_rate_limit).to eq(0)
  ensure
    original ? ENV["RAILWATCH_BEACON_RATE_LIMIT"] = original : ENV.delete("RAILWATCH_BEACON_RATE_LIMIT")
  end

  it "answers 204 rather than 429 when the beacon is disabled, whatever the client has sent before" do
    Railwatch.config.beacon_rate_limit = 1
    Railwatch.config.beacon_enabled = false

    3.times { post_beacon }
    expect(response).to have_http_status(:no_content)
    expect(railwatch_records(:visit)).to be_empty
  ensure
    Railwatch.config.beacon_enabled = true
  end

  it "refuses the beacon past the limit with a Retry-After, and records nothing from it" do
    Railwatch.config.beacon_rate_limit = 2

    2.times { post_beacon }
    expect(response).to have_http_status(:no_content)
    post_beacon
    expect(response).to have_http_status(:too_many_requests)
    expect(response.headers["Retry-After"]).to eq("60")
    expect(railwatch_records(:visit).size).to eq(2)
  end

  it "counts each client address on its own" do
    Railwatch.config.beacon_rate_limit = 1

    post_beacon(ip: "203.0.113.7")
    post_beacon(ip: "203.0.113.8")
    expect(response).to have_http_status(:no_content)
    post_beacon(ip: "203.0.113.7")
    expect(response).to have_http_status(:too_many_requests)
  end

  it "does not throttle when the limit is zero" do
    Railwatch.config.beacon_rate_limit = 0

    3.times { post_beacon }
    expect(response).to have_http_status(:no_content)
    expect(railwatch_records(:visit).size).to eq(3)
  end

  # Fails CLOSED, deliberately. The beacon is unauthenticated by design (any
  # browser on the app posts to it), so a store that cannot count would
  # otherwise leave an unlimited public write endpoint. An app that wants no
  # limit says so with beacon_rate_limit = 0, which is checked above.
  it "refuses the beacon on a cache store that cannot count, rather than serving an unlimited public endpoint" do
    Railwatch.config.beacon_rate_limit = 1
    allow_any_instance_of(Railwatch::BeaconController).to receive(:cache_store).and_return(ActiveSupport::Cache::NullStore.new)

    post_beacon
    expect(response).to have_http_status(:too_many_requests)
    expect(railwatch_records(:visit)).to be_empty
  end
end
