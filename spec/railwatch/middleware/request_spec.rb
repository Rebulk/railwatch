# frozen_string_literal: true

require "spec_helper"

RSpec.describe Railwatch::Middleware::Request do
  def env_for(url, method: "GET", headers: {})
    Rack::MockRequest.env_for(url, method: method).merge(headers)
  end

  def middleware(seen = nil)
    described_class.new(lambda do |_env|
      seen << Railwatch.execution if seen
      [ 204, { "Content-Type" => "text/plain", "Content-Length" => "0" }, [] ]
    end)
  end

  it "does not open an execution when Railwatch is disabled" do
    Railwatch.config.enabled = false
    seen = []

    middleware(seen).call(env_for("http://customer.test/widgets"))

    expect(seen).to eq([ nil ])
    expect(Railwatch.execution).to be_nil
    expect(railwatch_records).to be_empty
  ensure
    Railwatch.config.enabled = true
  end

  it "does not record the default health path" do
    seen = []

    middleware(seen).call(env_for("http://customer.test/up"))

    expect(seen).to eq([ nil ])
    expect(railwatch_records).to be_empty
  end

  it "does not record a custom exact or regexp path" do
    Railwatch.config.ignored_request_paths += [ "/healthz", %r{\A/internal/health/} ]

    middleware.call(env_for("http://customer.test/healthz"))
    middleware.call(env_for("http://customer.test/internal/health/ready"))

    expect(railwatch_records).to be_empty
  ensure
    Railwatch.config.ignored_request_paths = Railwatch::Configuration::DEFAULT_IGNORED_REQUEST_PATHS.dup
  end

  it "still records an unrelated customer route named /ingest" do
    middleware.call(env_for("http://customer.test/ingest", method: "POST",
                            headers: { "HTTP_AUTHORIZATION" => "Bearer #{Railwatch.config.token}" }))

    request = railwatch_records(:request).sole
    expect(request).to include(method: "POST", path: "/ingest", status_code: 204)
  end

  it "still records a same-origin /ingest request that is not Railwatch's transport" do
    Railwatch.config.ingest_url = "http://customer.test"

    middleware.call(env_for("http://customer.test/ingest", method: "POST"))

    expect(railwatch_records(:request).sole[:path]).to eq("/ingest")
  ensure
    Railwatch.config.ingest_url = "http://railwatch.test"
  end

  it "does not record the reporter's request to a same-origin ingest endpoint" do
    Railwatch.config.ingest_url = "https://railwatch.test"
    seen = []

    middleware(seen).call(env_for("https://railwatch.test/ingest", method: "POST",
                                  headers: { "HTTP_AUTHORIZATION" => "Bearer #{Railwatch.config.token}" }))

    expect(seen).to eq([ nil ])
    expect(railwatch_records).to be_empty
  ensure
    Railwatch.config.ingest_url = "http://railwatch.test"
  end

  it "recognizes the public ingest origin behind a TLS-terminating proxy" do
    Railwatch.config.ingest_url = "https://railwatch.test:8443"
    env = env_for("http://10.0.0.4:3000/ingest", method: "POST", headers: {
      "HTTP_AUTHORIZATION" => "Bearer #{Railwatch.config.token}",
      "HTTP_X_FORWARDED_HOST" => "edge.internal, railwatch.test",
      "HTTP_X_FORWARDED_PROTO" => "http, https",
      "HTTP_X_FORWARDED_PORT" => "8443"
    })

    middleware.call(env)

    expect(railwatch_records).to be_empty
  ensure
    Railwatch.config.ingest_url = "http://railwatch.test"
  end

  it "does not create a new record when delivering a request batch to itself" do
    Railwatch.config.ingest_url = "https://railwatch.test"
    deliveries = 0
    receiver = middleware
    ingest_env = env_for("https://railwatch.test/ingest", method: "POST",
                         headers: { "HTTP_AUTHORIZATION" => "Bearer #{Railwatch.config.token}" })
    transport = Object.new
    transport.define_singleton_method(:deliver) do |_records, dropped: 0, **|
      deliveries += 1
      receiver.call(ingest_env.dup)
      Railwatch::Transport::Http::Result.new(ok: true, status: 200, accepted: 1, rejected: 0)
    end
    reporter = Railwatch::Reporter.new(Railwatch.config, transport: transport)
    Railwatch.instance_variable_set(:@reporter, reporter)

    middleware.call(env_for("https://railwatch.test/widgets"))
    reporter.flush
    reporter.flush

    expect(deliveries).to eq(1)
    expect(reporter.buffer.size).to eq(0)
  ensure
    reporter&.shutdown
    Railwatch.config.ingest_url = "http://railwatch.test"
  end

  it "does not read a non-multipart request body while finishing a request no controller handled" do
    %w[application/json application/x-www-form-urlencoded].each do |content_type|
      input = Object.new
      %i[read gets each rewind].each do |method|
        input.define_singleton_method(method) { |*| raise "request body was parsed" }
      end
      env = env_for("http://customer.test/rejected", method: "POST", headers: {
        "CONTENT_TYPE" => content_type, "CONTENT_LENGTH" => "10000000", "rack.input" => input
      })

      expect { middleware.call(env) }.not_to raise_error
    end

    expect(railwatch_records(:request).map { |request| request[:files] }).to eq([ [], [] ])
  end

  # The request specs drive ActionDispatch::Static itself; these pin the
  # two conditions besides "no route" that a static file needs.
  describe "a request for a file in public/ that no route matched" do
    let(:asset) { "http://customer.test/vite/assets/dist-DedfDSJv.js" }

    it "is still recorded when it is not a GET or HEAD, which Static never serves" do
      middleware.call(env_for(asset, method: "POST"))

      expect(railwatch_records(:request).sole).to include(method: "POST", path: "/vite/assets/dist-DedfDSJv.js")
    end

    it "is still recorded when the path names no file, whatever the status" do
      middleware.call(env_for("http://customer.test/vite/assets/dist-B0Lc4rzm.js"))

      expect(railwatch_records(:request).sole).to include(path: "/vite/assets/dist-B0Lc4rzm.js", status_code: 204)
    end

    it "is skipped when it is a GET or HEAD for a file that is there" do
      middleware.call(env_for(asset))
      middleware.call(env_for(asset, method: "HEAD"))

      expect(railwatch_records(:request)).to be_empty
    end
  end

  describe "timing headers" do
    before { Railwatch.config.timing_headers = true }
    after { Railwatch.config.timing_headers = nil }

    def respond_with(headers)
      described_class.new(->(_env) { [ 200, headers, [] ] })
    end

    it "appends to a Server-Timing the app already set, whatever its case" do
      _, headers, = respond_with({ "Server-Timing" => "sql.active_record;dur=1.00" }).call(env_for("http://customer.test/widgets"))

      expect(headers.keys).not_to include("Server-Timing")
      expect(headers["server-timing"]).to start_with("sql.active_record;dur=1.00, total;dur=")
      expect(headers["server-timing"]).to include('db;desc="0 queries"')
    end

    it "leaves out the execution id when the request was sampled out, since the server never gets it" do
      Railwatch.config.sample = Railwatch.config.sample.merge(requests: 0.0)

      _, headers, = respond_with({}).call(env_for("http://customer.test/widgets"))

      expect(headers).not_to have_key("x-railwatch-execution-id")
      expect(headers["server-timing"]).to start_with("total;dur=")
    end

    it "keeps every value of an array-valued Server-Timing" do
      _, headers, = respond_with({ "server-timing" => [ "cache;dur=2", "app;dur=3" ] }).call(env_for("http://customer.test/widgets"))

      expect(headers["server-timing"]).to start_with("cache;dur=2, app;dur=3, total;dur=")
    end

    it "names an execution the tail decision kept, though the head sampled it out" do
      Railwatch.config.sample = Railwatch.config.sample.merge(requests: 0.0)
      Railwatch.config.tail_sample_slow_ms = 0.0

      _, headers, = respond_with({}).call(env_for("http://customer.test/widgets"))

      expect(headers["x-railwatch-execution-id"]).to eq(railwatch_records(:request).sole[:execution_id])
    ensure
      Railwatch.config.tail_sample_slow_ms = nil
    end

    it "leaves a frozen header hash alone" do
      frozen = { "content-type" => "text/plain" }.freeze

      _, headers, = respond_with(frozen).call(env_for("http://customer.test/widgets"))

      expect(headers).to equal(frozen)
      expect(railwatch_records(:request).size).to eq(1)
    end

    it "is on by default only in development" do
      Railwatch.config.timing_headers = nil
      expect(Railwatch.config.timing_headers?).to be(false)
      allow(Rails).to receive(:env).and_return(ActiveSupport::EnvironmentInquirer.new("development"))
      expect(Railwatch.config.timing_headers?).to be(true)
      Railwatch.config.timing_headers = false
      expect(Railwatch.config.timing_headers?).to be(false)
    end
  end
end
