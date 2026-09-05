# frozen_string_literal: true

require "spec_helper"
require "rack/tempfile_reaper"

RSpec.describe Lantern::Middleware::Request do
  def env_for(url, method: "GET", headers: {})
    Rack::MockRequest.env_for(url, method: method).merge(headers)
  end

  def middleware(seen = nil)
    described_class.new(lambda do |_env|
      seen << Lantern.execution if seen
      [ 204, { "Content-Type" => "text/plain", "Content-Length" => "0" }, [] ]
    end)
  end

  it "does not open an execution when Lantern is disabled" do
    Lantern.config.enabled = false
    seen = []

    middleware(seen).call(env_for("http://customer.test/widgets"))

    expect(seen).to eq([ nil ])
    expect(Lantern.execution).to be_nil
    expect(lantern_records).to be_empty
  ensure
    Lantern.config.enabled = true
  end

  it "does not record the default health path" do
    seen = []

    middleware(seen).call(env_for("http://customer.test/up"))

    expect(seen).to eq([ nil ])
    expect(lantern_records).to be_empty
  end

  it "does not record a custom exact or regexp path" do
    Lantern.config.ignored_request_paths += [ "/healthz", %r{\A/internal/health/} ]

    middleware.call(env_for("http://customer.test/healthz"))
    middleware.call(env_for("http://customer.test/internal/health/ready"))

    expect(lantern_records).to be_empty
  ensure
    Lantern.config.ignored_request_paths = Lantern::Configuration::DEFAULT_IGNORED_REQUEST_PATHS.dup
  end

  it "still records an unrelated customer route named /ingest" do
    middleware.call(env_for("http://customer.test/ingest", method: "POST",
                            headers: { "HTTP_AUTHORIZATION" => "Bearer #{Lantern.config.token}" }))

    request = lantern_records(:request).sole
    expect(request).to include(method: "POST", path: "/ingest", status_code: 204)
  end

  it "still records a same-origin /ingest request that is not Lantern's transport" do
    Lantern.config.ingest_url = "http://customer.test"

    middleware.call(env_for("http://customer.test/ingest", method: "POST"))

    expect(lantern_records(:request).sole[:path]).to eq("/ingest")
  ensure
    Lantern.config.ingest_url = "http://lantern.test"
  end

  it "does not record the reporter's request to a same-origin ingest endpoint" do
    Lantern.config.ingest_url = "https://lantern.test"
    seen = []

    middleware(seen).call(env_for("https://lantern.test/ingest", method: "POST",
                                  headers: { "HTTP_AUTHORIZATION" => "Bearer #{Lantern.config.token}" }))

    expect(seen).to eq([ nil ])
    expect(lantern_records).to be_empty
  ensure
    Lantern.config.ingest_url = "http://lantern.test"
  end

  it "recognizes the public ingest origin behind a TLS-terminating proxy" do
    Lantern.config.ingest_url = "https://lantern.test:8443"
    env = env_for("http://10.0.0.4:3000/ingest", method: "POST", headers: {
      "HTTP_AUTHORIZATION" => "Bearer #{Lantern.config.token}",
      "HTTP_X_FORWARDED_HOST" => "edge.internal, lantern.test",
      "HTTP_X_FORWARDED_PROTO" => "http, https",
      "HTTP_X_FORWARDED_PORT" => "8443"
    })

    middleware.call(env)

    expect(lantern_records).to be_empty
  ensure
    Lantern.config.ingest_url = "http://lantern.test"
  end

  it "does not create a new record when delivering a request batch to itself" do
    Lantern.config.ingest_url = "https://lantern.test"
    deliveries = 0
    receiver = middleware
    ingest_env = env_for("https://lantern.test/ingest", method: "POST",
                         headers: { "HTTP_AUTHORIZATION" => "Bearer #{Lantern.config.token}" })
    transport = Object.new
    transport.define_singleton_method(:deliver) do |_records, dropped: 0|
      deliveries += 1
      receiver.call(ingest_env.dup)
      Lantern::Transport::Http::Result.new(ok: true, status: 200, accepted: 1, rejected: 0)
    end
    reporter = Lantern::Reporter.new(Lantern.config, transport: transport)
    Lantern.instance_variable_set(:@reporter, reporter)

    middleware.call(env_for("https://lantern.test/widgets"))
    reporter.flush
    reporter.flush

    expect(deliveries).to eq(1)
    expect(reporter.buffer.size).to eq(0)
  ensure
    reporter&.shutdown
    Lantern.config.ingest_url = "http://lantern.test"
  end

  it "does not read rejected JSON or form bodies while finishing telemetry" do
    %w[application/json application/x-www-form-urlencoded].each do |content_type|
      input = Object.new
      input.define_singleton_method(:read) { |*| raise "request body was parsed" }
      input.define_singleton_method(:gets) { |*| raise "request body was parsed" }
      input.define_singleton_method(:each) { |*| raise "request body was parsed" }
      input.define_singleton_method(:rewind) { raise "request body was parsed" }
      env = env_for("http://customer.test/rejected", method: "POST", headers: {
        "CONTENT_TYPE" => content_type, "CONTENT_LENGTH" => "10000000", "rack.input" => input
      })

      expect { middleware.call(env) }.not_to raise_error
    end

    expect(lantern_records(:request).map { |request| request[:files] }).to eq([ [], [] ])
  end

  it "preserves the parent when multipart upload inspection raises" do
    calls = []
    input = Object.new
    %i[read gets each rewind].each do |method|
      input.define_singleton_method(method) { |*| calls << method; raise IOError, "hostile #{method}" }
    end
    env = env_for("http://customer.test/rejected", method: "POST", headers: {
      "CONTENT_TYPE" => "Multipart/Form-Data; boundary=x", "CONTENT_LENGTH" => "10000000", "rack.input" => input
    })
    rejecting = described_class.new(->(_) { [ 413, { "Content-Type" => "text/plain" }, [] ] })

    status, = rejecting.call(env)

    expect(status).to eq(413)
    expect(calls).not_to be_empty
    expect(lantern_records(:request).sole).to include(status_code: 413, files: [])
  end

  it "does not parse multipart uploads after Rack has unwound an app exception" do
    boundary = "AaB03x"
    body = "--#{boundary}\r\nContent-Disposition: form-data; name=\"attachment\"; filename=\"a.txt\"\r\n" \
      "Content-Type: text/plain\r\n\r\nhello\r\n--#{boundary}--\r\n"
    env = env_for("http://customer.test/boom", method: "POST", headers: {
      "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}", "CONTENT_LENGTH" => body.bytesize.to_s,
      "rack.input" => StringIO.new(body)
    })
    error = Class.new(StandardError)
    inner = Rack::TempfileReaper.new(->(_) { raise error, "original app error" })

    expect { described_class.new(inner).call(env) }.to raise_error(error, "original app error")

    expect(env.fetch("rack.tempfiles")).to be_empty
    expect(lantern_records(:request).sole[:files]).to eq([])
  ensure
    env&.fetch("rack.tempfiles", [])&.each(&:close!)
  end

  it "omits a failed opt-in payload without losing the parent or masking the app error" do
    Lantern.config.capture_request_payload = true
    input = Object.new
    %i[read gets each rewind].each do |method|
      input.define_singleton_method(method) { |*| raise IOError, "hostile #{method}" }
    end
    env = env_for("http://customer.test/boom", method: "POST", headers: {
      "CONTENT_TYPE" => "application/json", "CONTENT_LENGTH" => "10000000", "rack.input" => input
    })
    error = Class.new(StandardError)

    expect {
      described_class.new(->(_) { raise error, "original app error" }).call(env)
    }.to raise_error(error, "original app error")

    expect(lantern_records(:exception).sole[:message]).to eq("original app error")
    expect(lantern_records(:request).sole[:payload]).to be_nil
  ensure
    Lantern.config.capture_request_payload = false
  end
end
