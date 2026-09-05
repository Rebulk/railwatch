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

  def multipart_body(boundary)
    "--#{boundary}\r\nContent-Disposition: form-data; name=\"attachment\"; filename=\"a.txt\"\r\n" \
      "Content-Type: text/plain\r\n\r\nhello\r\n--#{boundary}--\r\n"
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

  it "does not finish a nested parent when writing the request record fails" do
    parent = Lantern.start_execution(source: :job)
    fail_next_write = true
    allow(Lantern.reporter).to receive(:write).and_wrap_original do |original, record|
      if fail_next_write
        fail_next_write = false
        raise "reporter write failed"
      end
      original.call(record)
    end

    status, = middleware.call(env_for("http://customer.test/widgets"))

    expect(status).to eq(204)
    expect(Lantern.execution).to equal(parent)
    Lantern.record(:span, name: "parent continued")
    Lantern.finish_execution
    expect(lantern_records(:span).sole[:name]).to eq("parent continued")
  ensure
    Lantern::Current.clear
  end

  it "does not finish a nested parent when session tracking fails after request finalization" do
    Lantern.config.track_sessions = true
    parent = Lantern.start_execution(source: :job)
    allow(Lantern::Sessions).to receive(:touch).and_raise("session tracking failed")

    status, = middleware.call(env_for("http://customer.test/widgets"))

    expect(status).to eq(204)
    expect(Lantern.execution).to equal(parent)
    Lantern.finish_execution
    expect(Lantern.execution).to be_nil
  ensure
    Lantern.config.track_sessions = false
    Lantern::Current.clear
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
      calls = []
      input = Object.new
      %i[read gets each rewind].each do |method|
        input.define_singleton_method(method) do |*|
          calls << method
          raise "request body was parsed"
        end
      end
      env = env_for("http://customer.test/rejected", method: "POST", headers: {
        "CONTENT_TYPE" => content_type, "CONTENT_LENGTH" => "10000000", "rack.input" => input
      })

      expect { middleware.call(env) }.not_to raise_error
      expect(calls).to be_empty
    end

    expect(lantern_records(:request).map { |request| request[:files] }).to eq([ [], [] ])
  end

  it "does not parse an uncached multipart body without a tempfile reaper" do
    boundary = "AaB03x"
    body = multipart_body(boundary)
    calls = []
    input = StringIO.new(body)
    tracker = Module.new do
      %i[read gets each rewind].each do |method|
        define_method(method) do |*args, &block|
          calls << method
          super(*args, &block)
        end
      end
    end
    input.singleton_class.prepend(tracker)
    env = env_for("http://customer.test/rejected", method: "POST", headers: {
      "CONTENT_TYPE" => "Multipart/Form-Data; boundary=#{boundary}", "CONTENT_LENGTH" => body.bytesize.to_s,
      "rack.input" => input
    })
    rejecting = described_class.new(->(_) { [ 413, { "Content-Type" => "text/plain" }, [] ] })

    status, = rejecting.call(env)

    expect(status).to eq(413)
    expect(calls).to be_empty
    expect(env.fetch("rack.tempfiles", [])).to be_empty
    expect(lantern_records(:request).sole).to include(status_code: 413, files: [])
  end

  it "uses multipart parameters that upstream code already cached" do
    file = Tempfile.new([ "cached-upload", ".txt" ])
    file.write("hello")
    file.rewind
    upload = ActionDispatch::Http::UploadedFile.new(
      tempfile: file, filename: "a.txt", type: "text/plain", headers: ""
    )
    env = env_for("http://customer.test/upload", method: "POST", headers: {
      "CONTENT_TYPE" => "multipart/form-data; boundary=already-parsed",
      "action_dispatch.request.request_parameters" => { "attachment" => upload }
    })

    middleware.call(env)

    expect(lantern_records(:request).sole[:files].sole).to include(
      name: "attachment", size: 5, content_type: "text/plain"
    )
  ensure
    file&.close!
  end

  it "does not parse multipart uploads after Rack has unwound an app exception" do
    boundary = "AaB03x"
    body = multipart_body(boundary)
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

  it "does not parse multipart after outer middleware catches an exception from inside the tempfile reaper" do
    boundary = "AaB03x"
    body = multipart_body(boundary)
    env = env_for("http://customer.test/boom", method: "POST", headers: {
      "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}", "CONTENT_LENGTH" => body.bytesize.to_s,
      "rack.input" => StringIO.new(body)
    })
    inner = Rack::TempfileReaper.new(->(_) { raise "original app error" })
    catcher = lambda do |request_env|
      inner.call(request_env)
    rescue StandardError
      [ 500, { "Content-Type" => "text/plain" }, [] ]
    end

    status, = described_class.new(catcher).call(env)

    expect(status).to eq(500)
    expect(env.fetch("rack.tempfiles")).to be_empty
    expect(lantern_records(:request).sole).to include(status_code: 500, files: [])
  ensure
    env&.fetch("rack.tempfiles", [])&.each(&:close!)
  end

  it "does not parse an opt-in payload after an outer catcher and tempfile reaper unwind" do
    Lantern.config.capture_request_payload = true
    boundary = "AaB03x"
    body = multipart_body(boundary)
    calls = []
    input = StringIO.new(body)
    tracker = Module.new do
      %i[read gets each rewind].each do |method|
        define_method(method) do |*args, &block|
          calls << method
          super(*args, &block)
        end
      end
    end
    input.singleton_class.prepend(tracker)
    env = env_for("http://customer.test/boom", method: "POST", headers: {
      "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}", "CONTENT_LENGTH" => body.bytesize.to_s,
      "rack.input" => input
    })
    failing = lambda do |_request_env|
      Lantern.report(RuntimeError.new("handled before the app failure"))
      raise "original app error"
    end
    inner = Rack::TempfileReaper.new(failing)
    catcher = lambda do |request_env|
      inner.call(request_env)
    rescue StandardError
      [ 500, { "Content-Type" => "text/plain" }, [] ]
    end

    status, = described_class.new(catcher).call(env)

    expect(status).to eq(500)
    expect(calls).to be_empty
    expect(env.fetch("rack.tempfiles")).to be_empty
    expect(lantern_records(:request).sole).to include(status_code: 500, payload: nil, files: [])
    expect(Lantern::Current.execution).to be_nil
  ensure
    env&.fetch("rack.tempfiles", [])&.each(&:close!)
    Lantern.config.capture_request_payload = false
  end

  it "preserves successful responses and original errors for cyclic cached parameters" do
    cycle = {}
    cycle["self"] = cycle
    success_env = env_for("http://customer.test/upload", method: "POST", headers: {
      "CONTENT_TYPE" => "multipart/form-data; boundary=x",
      "action_dispatch.request.request_parameters" => cycle
    })

    status, = middleware.call(success_env)

    expect(status).to eq(204)
    expect(lantern_records(:request).sole).to include(status_code: 204, files: [])
    expect(Lantern::Current.execution).to be_nil

    error_env = success_env.dup
    original = Class.new(StandardError)
    expect do
      described_class.new(->(_) { raise original, "original app error" }).call(error_env)
    end.to raise_error(original, "original app error")
    expect(Lantern::Current.execution).to be_nil
  end

  it "fails closed on cyclic cached opt-in payloads" do
    Lantern.config.capture_request_payload = true
    cycle = {}
    cycle["self"] = cycle
    env = env_for("http://customer.test/api", method: "POST", headers: {
      "CONTENT_TYPE" => "application/json",
      "action_dispatch.request.request_parameters" => cycle
    })
    app = lambda do |_request_env|
      Lantern.report(RuntimeError.new("handled"))
      [ 422, { "Content-Type" => "application/json" }, [] ]
    end

    status, = described_class.new(app).call(env)

    expect(status).to eq(422)
    expect(lantern_records(:request).sole).to include(status_code: 422, payload: nil)
    expect(Lantern::Current.execution).to be_nil
  ensure
    Lantern.config.capture_request_payload = false
  end

  it "uses Rack-native multipart parameters only after Rack cached them" do
    boundary = "AaB03x"
    body = multipart_body(boundary)
    env = env_for("http://customer.test/upload", method: "POST", headers: {
      "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}", "CONTENT_LENGTH" => body.bytesize.to_s,
      "rack.input" => StringIO.new(body)
    })
    app = lambda do |request_env|
      Rack::Request.new(request_env).POST
      [ 201, { "Content-Type" => "text/plain" }, [] ]
    end

    status, = described_class.new(app).call(env)

    expect(status).to eq(201)
    expect(lantern_records(:request).sole[:files].sole).to include(
      name: "attachment", size: 5, content_type: "text/plain"
    )
  ensure
    env&.fetch("rack.tempfiles", [])&.each(&:close!)
  end

  it "makes malformed multipart upload metadata safe to encode" do
    boundary = "AaB03x"
    invalid_content_type = "\xFF".b
    body = "--#{boundary}\r\nContent-Disposition: form-data; name=\"attachment\"; filename=\"a.txt\"\r\n".b +
           "Content-Type: ".b + invalid_content_type +
           "\r\n\r\nhello\r\n--#{boundary}--\r\n".b
    env = env_for("http://customer.test/upload", method: "POST", headers: {
      "CONTENT_TYPE" => "multipart/form-data; boundary=#{boundary}", "CONTENT_LENGTH" => body.bytesize.to_s,
      "rack.input" => StringIO.new(body)
    })
    app = lambda do |request_env|
      ActionDispatch::Request.new(request_env).request_parameters
      [ 201, { "Content-Type" => "text/plain" }, [] ]
    end

    status, = described_class.new(app).call(env)

    expect(status).to eq(201)
    record = lantern_records(:request).sole
    content_type = record[:files].sole[:content_type]
    expect(content_type.encoding).to eq(Encoding::UTF_8)
    expect(content_type).to be_valid_encoding
    expect(content_type).to eq("\uFFFD")
    expect { JSON.generate(record) }.not_to raise_error
    transport = Lantern::Transport::Http.new(Lantern.config)
    expect { transport.send(:encode, [ record ]) }.not_to raise_error
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
