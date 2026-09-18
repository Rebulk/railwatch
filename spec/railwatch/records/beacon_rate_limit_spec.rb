# frozen_string_literal: true

require "spec_helper"

RSpec.describe "beacon rate limit", type: :request do
  def post_beacon(ip: "203.0.113.7", headers: {})
    post "/railwatch/beacon",
         params: { visits: [ { component: "Widgets/Index", url: "/widgets", method: "GET",
                               started_at: Time.now.to_f * 1000, duration_ms: 1, status: "200" } ] }.to_json,
         headers: { "Content-Type" => "application/json", "REMOTE_ADDR" => ip }.merge(headers)
  end

  around do |example|
    original = Railwatch.config.beacon_rate_limit
    global = Railwatch.config.beacon_global_rate_limit
    origins = Railwatch.config.beacon_allowed_origins
    Rails.cache.clear
    example.run
  ensure
    Railwatch.config.beacon_rate_limit = original
    Railwatch.config.beacon_global_rate_limit = global
    Railwatch.config.beacon_allowed_origins = origins
    Rails.cache.clear
  end

  # The endpoint is public by design -- a browser cannot hold a credential
  # the page does not already give away -- so what bounds it is the shape a
  # hosted product uses: an origin allowlist, a per-client ceiling, and one
  # for the endpoint as a whole.
  describe "origin" do
    it "accepts the app's own origin, and a request that names none" do
      post_beacon(headers: { "HTTP_ORIGIN" => "http://www.example.com" })
      expect(response).to have_http_status(:no_content)

      post_beacon
      expect(response).to have_http_status(:no_content)
    end

    it "refuses another site's page spending this app's quota" do
      post_beacon(headers: { "HTTP_ORIGIN" => "https://evil.example" })
      expect(response).to have_http_status(:forbidden)
      expect(railwatch_records(:visit)).to be_empty
    end

    it "falls back to the referer when there is no origin" do
      post_beacon(headers: { "HTTP_REFERER" => "https://evil.example/page" })
      expect(response).to have_http_status(:forbidden)
    end

    it "allows an origin the app listed, by full origin or bare host" do
      Railwatch.config.beacon_allowed_origins = [ "https://app.example.com", "cdn.example.org" ]

      post_beacon(headers: { "HTTP_ORIGIN" => "https://app.example.com" })
      expect(response).to have_http_status(:no_content)
      post_beacon(headers: { "HTTP_ORIGIN" => "https://cdn.example.org" })
      expect(response).to have_http_status(:no_content)
      post_beacon(headers: { "HTTP_ORIGIN" => "https://other.example.org" })
      expect(response).to have_http_status(:forbidden)
    end
  end

  it "stops the endpoint as a whole once the global ceiling is passed, whatever address it comes from" do
    Railwatch.config.beacon_rate_limit = 1_000
    Railwatch.config.beacon_global_rate_limit = 2

    2.times { |i| post_beacon(ip: "198.51.100.#{i}") }
    expect(response).to have_http_status(:no_content)

    post_beacon(ip: "198.51.100.99")
    expect(response).to have_http_status(:too_many_requests)
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
