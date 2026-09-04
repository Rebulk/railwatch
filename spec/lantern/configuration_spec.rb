# frozen_string_literal: true

require "spec_helper"

RSpec.describe Lantern::Configuration do
  # Builds a fresh Configuration under a patched ENV, then restores ENV.
  # Configuration reads ENV only in #initialize, so every case needs its own instance.
  def with_env(pairs)
    original = {}
    pairs.each { |k, v| original[k] = ENV[k]; v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield described_class.new
  ensure
    original.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  describe "env var defaults and overrides" do
    {
      "LANTERN_ENABLED" => [ :enabled, "0", false, true ],
      "LANTERN_TOKEN" => [ :token, "abc123", "abc123", nil ],
      "LANTERN_INGEST_URL" => [ :ingest_url, "https://custom.example", "https://custom.example", "https://lantern.rebulk.com" ],
      "LANTERN_SERVER" => [ :server, "web-1", "web-1", ENV["KAMAL_HOST"] || Socket.gethostname ],
      "LANTERN_LOG_LEVEL" => [ :log_level, "debug", :debug, :info ],
      "LANTERN_CAPTURE_REQUEST_PAYLOAD" => [ :capture_request_payload, "1", true, false ],
      "LANTERN_CAPTURE_EXCEPTION_SOURCE_CODE" => [ :capture_exception_source, "0", false, true ],
      "LANTERN_BUFFER_SIZE" => [ :buffer_size, "9999", 9_999, 5_000 ],
      "LANTERN_FLUSH_INTERVAL" => [ :flush_interval, "7.5", 7.5, 2.0 ],
      "LANTERN_FLUSH_THRESHOLD" => [ :flush_threshold, "50", 50, 500 ],
      "LANTERN_CONNECT_TIMEOUT" => [ :connect_timeout, "0.5", 0.5, 1.0 ],
      "LANTERN_TIMEOUT" => [ :timeout, "9.0", 9.0, 3.0 ],
      "LANTERN_SHUTDOWN_TIMEOUT" => [ :shutdown_timeout, "4.0", 4.0, 2.0 ],
      "LANTERN_SLOW_QUERY_MS" => [ :slow_query_threshold_ms, "12.0", 12.0, 5.0 ],
      "LANTERN_N_PLUS_ONE_THRESHOLD" => [ :n_plus_one_threshold, "9", 9, 5 ],
      "LANTERN_HEALTH_INTERVAL" => [ :health_interval, "60.0", 60.0, 15.0 ],
      "LANTERN_CAPTURE_QUERY_EXPLAIN" => [ :capture_query_explain, "1", true, false ],
      "LANTERN_EXPLAIN_THRESHOLD_MS" => [ :explain_threshold_ms, "250.0", 250.0, 100.0 ],
      "LANTERN_CAPTURE_RESCUED_EXCEPTIONS" => [ :capture_rescued_exceptions, "0", false, true ],
      "LANTERN_BEACON" => [ :beacon_enabled, "0", false, true ],
      "LANTERN_DEBUG" => [ :debug, "1", true, false ]
    }.each do |env_key, (attr, raw, expected, default)|
      it "maps #{env_key} to config.#{attr}, defaulting to #{default.inspect}" do
        with_env(env_key => raw) { |config| expect(config.public_send(attr)).to eq(expected) }
        with_env(env_key => nil) { |config| expect(config.public_send(attr)).to eq(default) }
      end
    end

    it "maps LANTERN_REQUEST/JOB/COMMAND/SCHEDULED_TASK/EXCEPTION_SAMPLE_RATE into config.sample, defaulting every kind to 1.0" do
      with_env(
        "LANTERN_REQUEST_SAMPLE_RATE" => "0.2", "LANTERN_JOB_SAMPLE_RATE" => "0.3",
        "LANTERN_COMMAND_SAMPLE_RATE" => "0.4", "LANTERN_SCHEDULED_TASK_SAMPLE_RATE" => "0.5",
        "LANTERN_EXCEPTION_SAMPLE_RATE" => "0.6"
      ) do |config|
        expect(config.sample).to eq(requests: 0.2, jobs: 0.3, commands: 0.4, scheduled_tasks: 0.5, exceptions: 0.6)
      end
      with_env(
        "LANTERN_REQUEST_SAMPLE_RATE" => nil, "LANTERN_JOB_SAMPLE_RATE" => nil, "LANTERN_COMMAND_SAMPLE_RATE" => nil,
        "LANTERN_SCHEDULED_TASK_SAMPLE_RATE" => nil, "LANTERN_EXCEPTION_SAMPLE_RATE" => nil
      ) do |config|
        expect(config.sample).to eq(requests: 1.0, jobs: 1.0, commands: 1.0, scheduled_tasks: 1.0, exceptions: 1.0)
      end
    end

    it "maps LANTERN_DEPLOY, falling back to KAMAL_VERSION then GIT_REV then nil" do
      with_env("LANTERN_DEPLOY" => "v1", "KAMAL_VERSION" => "kamal-v", "GIT_REV" => "git-v") { |c| expect(c.deploy).to eq("v1") }
      with_env("LANTERN_DEPLOY" => nil, "KAMAL_VERSION" => "kamal-v", "GIT_REV" => "git-v") { |c| expect(c.deploy).to eq("kamal-v") }
      with_env("LANTERN_DEPLOY" => nil, "KAMAL_VERSION" => nil, "GIT_REV" => "git-v") { |c| expect(c.deploy).to eq("git-v") }
      with_env("LANTERN_DEPLOY" => nil, "KAMAL_VERSION" => nil, "GIT_REV" => nil) { |c| expect(c.deploy).to be_nil }
    end

    it "splits LANTERN_REDACT_HEADERS on commas, defaulting to the documented header list" do
      with_env("LANTERN_REDACT_HEADERS" => "X-Api-Key, X-Secret") do |config|
        expect(config.redact_headers).to eq(%w[X-Api-Key X-Secret])
      end
      with_env("LANTERN_REDACT_HEADERS" => nil) do |config|
        expect(config.redact_headers).to eq(%w[Authorization Cookie Set-Cookie Proxy-Authorization X-CSRF-Token X-XSRF-TOKEN])
      end
    end

    it "splits LANTERN_REDACT_PARAMS on commas, defaulting to the documented param list" do
      with_env("LANTERN_REDACT_PARAMS" => "ssn, credit_card") do |config|
        expect(config.redact_params).to eq(%w[ssn credit_card])
      end
      with_env("LANTERN_REDACT_PARAMS" => nil) do |config|
        expect(config.redact_params).to eq(%w[password password_confirmation authenticity_token _token])
      end
    end

    described_class::RECORD_TYPES.each do |type|
      it "maps LANTERN_IGNORE_#{type.to_s.upcase} to ignoring #{type}, defaulting to not ignored" do
        with_env("LANTERN_IGNORE_#{type.to_s.upcase}" => "1") { |c| expect(c.ignored?(type)).to be(true) }
        with_env("LANTERN_IGNORE_#{type.to_s.upcase}" => nil) { |c| expect(c.ignored?(type)).to be(false) }
      end
    end

    it "treats True/YES/On as truthy for LANTERN_IGNORE_* regardless of case" do
      %w[1 true True TRUE yes Yes on ON].each do |value|
        with_env("LANTERN_IGNORE_QUERIES" => value) { |c| expect(c.ignored?(:queries)).to be(true) }
      end
      %w[0 false no off garbage].each do |value|
        with_env("LANTERN_IGNORE_QUERIES" => value) { |c| expect(c.ignored?(:queries)).to be(false) }
      end
    end
  end

  describe "ignored_exceptions" do
    it "defaults to the Rails-relevant subset of Sentry's own excluded_exceptions" do
      with_env("LANTERN_IGNORED_EXCEPTIONS" => nil) do |config|
        expect(config.ignored_exceptions).to eq(described_class::DEFAULT_IGNORED_EXCEPTIONS)
        expect(config.ignored_exceptions).to include(
          "ActionController::RoutingError", "ActionController::InvalidAuthenticityToken",
          "ActiveRecord::RecordNotFound", "Rack::QueryParser::ParameterTypeError",
          "Puma::HttpParserError")
        # Interrupt < SignalException: a shutdown is not an error.
        expect(config.ignored_exceptions).to include("SignalException")
      end
    end

    it "hands out a mutable copy, so appending in one app can't leak into the frozen default" do
      config = described_class.new
      config.ignored_exceptions << "MyApp::Ignorable"
      expect(described_class::DEFAULT_IGNORED_EXCEPTIONS).not_to include("MyApp::Ignorable")
    end

    it "splits LANTERN_IGNORED_EXCEPTIONS on commas, replacing the default list" do
      with_env("LANTERN_IGNORED_EXCEPTIONS" => "Foo::Bar, Baz") do |config|
        expect(config.ignored_exceptions).to eq(%w[Foo::Bar Baz])
      end
    end
  end

  describe "#sample_rate" do
    it "clamps configured rates to 0.0..1.0" do
      config = described_class.new
      config.sample = { requests: 5.0, jobs: -2.0 }
      expect(config.sample_rate(:requests)).to eq(1.0)
      expect(config.sample_rate(:jobs)).to eq(0.0)
    end

    it "defaults an unknown sample kind to 1.0" do
      config = described_class.new
      expect(config.sample_rate(:some_new_kind)).to eq(1.0)
    end
  end

  describe "#ignore=" do
    it "raises ArgumentError for a type outside RECORD_TYPES" do
      config = described_class.new
      expect { config.ignore = [ :not_a_real_type ] }.to raise_error(ArgumentError)
    end
  end

  describe "#enabled?" do
    it "is false without a token even when LANTERN_ENABLED=1" do
      with_env("LANTERN_ENABLED" => "1", "LANTERN_TOKEN" => nil) { |c| expect(c.enabled?).to be(false) }
      with_env("LANTERN_ENABLED" => "1", "LANTERN_TOKEN" => "tok") { |c| expect(c.enabled?).to be(true) }
    end

    it "is false when LANTERN_ENABLED=0 even with a token" do
      with_env("LANTERN_ENABLED" => "0", "LANTERN_TOKEN" => "tok") { |c| expect(c.enabled?).to be(false) }
    end
  end

  describe "vendor default exclusion toggles" do
    it "defaults capture_default_vendor_commands and capture_default_vendor_cache_keys to false" do
      config = described_class.new
      expect(config.capture_default_vendor_commands).to be(false)
      expect(config.capture_default_vendor_cache_keys).to be(false)
    end

    it "maps LANTERN_CAPTURE_DEFAULT_VENDOR_COMMANDS/CACHE_KEYS to the toggles" do
      with_env("LANTERN_CAPTURE_DEFAULT_VENDOR_COMMANDS" => "1", "LANTERN_CAPTURE_DEFAULT_VENDOR_CACHE_KEYS" => "1") do |c|
        expect(c.capture_default_vendor_commands).to be(true)
        expect(c.capture_default_vendor_cache_keys).to be(true)
      end
    end
  end

  describe ".match_cache_key?" do
    it "matches a bare string exactly, not as a prefix" do
      expect(described_class.match_cache_key?("session:", "session:abc")).to be(false)
      expect(described_class.match_cache_key?("session:", "session:")).to be(true)
    end

    it "matches a trailing-star string as a prefix" do
      expect(described_class.match_cache_key?("session:*", "session:abc")).to be(true)
      expect(described_class.match_cache_key?("session:*", "usersession:abc")).to be(false)
    end

    it "compiles a leading-caret string as a regexp anchored to the start" do
      expect(described_class.match_cache_key?("^session:", "session:abc")).to be(true)
      expect(described_class.match_cache_key?("^session:", "usersession:abc")).to be(false)
    end

    it "uses a Regexp pattern as-is" do
      expect(described_class.match_cache_key?(/\Aflipper\//, "flipper/feature")).to be(true)
      expect(described_class.match_cache_key?(/\Aflipper\//, "not_flipper/feature")).to be(false)
    end
  end
end

RSpec.describe Lantern::Configuration, "server under Kamal" do
  def with_env(pairs)
    saved = pairs.keys.to_h { |k| [ k, ENV[k] ] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  it "stamps records with the Kamal host rather than the per-deploy container hostname" do
    with_env("KAMAL_HOST" => "5.78.218.245", "LANTERN_SERVER" => nil) do
      expect(described_class.new.server).to eq("5.78.218.245")
    end
  end

  it "still lets LANTERN_SERVER override the Kamal host" do
    with_env("KAMAL_HOST" => "5.78.218.245", "LANTERN_SERVER" => "web-1") do
      expect(described_class.new.server).to eq("web-1")
    end
  end
end
