# frozen_string_literal: true

require "spec_helper"
require "rack/lint"
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
    previous_track_sessions = Lantern.config.track_sessions
    Lantern.config.track_sessions = true
    parent = Lantern.start_execution(source: :job)
    allow(Lantern::Sessions).to receive(:touch).and_raise("session tracking failed")

    status, = middleware.call(env_for("http://customer.test/widgets"))

    expect(status).to eq(204)
    expect(Lantern.execution).to equal(parent)
    Lantern.finish_execution
    expect(Lantern.execution).to be_nil
  ensure
    Lantern.config.track_sessions = previous_track_sessions
    Lantern::Current.clear
  end

  it "never replaces an application error when exception reporting fails" do
    parent = Lantern.start_execution(source: :job)
    original = Class.new(StandardError)
    allow(Lantern.reporter).to receive(:write_now).and_raise("reporter write failed")

    expect do
      described_class.new(->(_) { raise original, "original app error" }).call(
        env_for("http://customer.test/boom")
      )
    end.to raise_error(original, "original app error")

    expect(Lantern.execution).to equal(parent)
    Lantern.record(:span, name: "parent survived exception reporting")
    Lantern.finish_execution
    expect(lantern_records(:span).sole[:name]).to eq("parent survived exception reporting")
  ensure
    Lantern::Current.clear
  end

  it "never replaces an application error when exception capture raises outside StandardError" do
    telemetry_error = Class.new(Exception)
    application_error = Class.new(StandardError)
    allow(Lantern::Subscribers::Exceptions).to receive(:capture).and_raise(telemetry_error, "telemetry fatal")

    expect do
      described_class.new(->(_) { raise application_error, "original app error" }).call(
        env_for("http://customer.test/boom")
      )
    end.to raise_error(application_error, "original app error")

    expect(Lantern.execution).to be_nil
  end

  it "never lets debug logging replace an application error" do
    telemetry_error = Class.new(Exception)
    application_error = Class.new(StandardError)
    allow(Lantern::Subscribers::Exceptions).to receive(:capture).and_raise("capture failed")
    allow(Lantern).to receive(:debug).and_raise(telemetry_error, "debug fatal")

    expect do
      described_class.new(->(_) { raise application_error, "original app error" }).call(
        env_for("http://customer.test/boom")
      )
    end.to raise_error(application_error, "original app error")

    expect(Lantern.execution).to be_nil
  end

  it "never replaces a successful response when request finalization raises outside StandardError" do
    telemetry_error = Class.new(Exception)
    allow(Lantern).to receive(:finish_execution).and_raise(telemetry_error, "finish fatal")

    status, headers, body = middleware.call(env_for("http://customer.test/widgets"))

    expect([ status, headers, body ]).to eq(
      [ 204, { "Content-Type" => "text/plain", "Content-Length" => "0" }, [] ]
    )
    expect(Lantern.execution).to be_nil
  end

  it "does not invoke a telemetry exception's overridden type predicate" do
    telemetry_error = Class.new(Exception).new("telemetry fatal")
    telemetry_error.define_singleton_method(:is_a?) { |_| raise "is_a replacement" }
    allow(Lantern).to receive(:finish_execution).and_raise(telemetry_error)

    status, = middleware.call(env_for("http://customer.test/widgets"))

    expect(status).to eq(204)
    expect(Lantern.execution).to be_nil
  end

  it "never replaces an application error when request finalization raises outside StandardError" do
    telemetry_error = Class.new(Exception)
    application_error = Class.new(StandardError)
    allow(Lantern).to receive(:finish_execution).and_raise(telemetry_error, "finish fatal")

    expect do
      described_class.new(->(_) { raise application_error, "original app error" }).call(
        env_for("http://customer.test/boom")
      )
    end.to raise_error(application_error, "original app error")

    expect(Lantern.execution).to be_nil
  end

  it "propagates a process signal from finalization when no application error is active" do
    allow(Lantern).to receive(:finish_execution).and_raise(SignalException.new("TERM"))

    expect do
      middleware.call(env_for("http://customer.test/widgets"))
    end.to raise_error(SignalException)

    expect(Lantern.execution).to be_nil
  end

  it "preserves an application error when finalization also raises a process signal" do
    application_error = Class.new(StandardError)
    allow(Lantern).to receive(:finish_execution).and_raise(SignalException.new("TERM"))

    expect do
      described_class.new(->(_) { raise application_error, "original app error" }).call(
        env_for("http://customer.test/boom")
      )
    end.to raise_error(application_error, "original app error")

    expect(Lantern.execution).to be_nil
  end

  it "stops a request profile without emitting when parent construction fails" do
    handle = Object.new
    Lantern.config.profile_sample = 1.0
    allow(Lantern::Profiler).to receive(:available?).and_return(true)
    allow(Lantern::Profiler).to receive(:start).and_return(handle)
    expect(Lantern::Profiler).to receive(:stop).with(handle).and_return(nil)
    request_middleware = middleware
    allow(request_middleware).to receive(:parent_fields).and_raise("parent construction failed")

    status, = request_middleware.call(env_for("http://customer.test/widgets"))

    expect(status).to eq(204)
    expect(lantern_records).to be_empty
    expect(Lantern.execution).to be_nil
  ensure
    Lantern.config.profile_sample = 0.0
  end

  it "keeps streaming enumeration and close inside the request execution" do
    seen = []
    close_calls = 0
    stream = Object.new
    stream.define_singleton_method(:each) do |&block|
      seen << [ :each, Lantern.execution ]
      Lantern.record(:span, name: "stream each")
      sleep 0.002
      block.call("one")
      block.call("two")
    end
    stream.define_singleton_method(:close) do
      close_calls += 1
      seen << [ :close, Lantern.execution ]
      Lantern.record(:span, name: "stream close")
    end
    headers = { "Content-Type" => "text/plain", "X-Stream" => "yes" }
    app = ->(env) { [ 206, headers, stream ] }

    status, returned_headers, body = described_class.new(app).call(env_for("http://customer.test/stream"))

    expect(status).to eq(206)
    expect(returned_headers).to equal(headers)
    expect(lantern_records).to be_empty
    expect(Lantern.execution).to be_nil

    chunks = []
    body.each { |chunk| chunks << chunk }

    expect(chunks).to eq(%w[one two])
    expect(close_calls).to eq(1)
    expect(seen.map(&:first)).to eq(%i[each close])
    expect(seen.map(&:last).uniq).to contain_exactly(an_instance_of(Lantern::Execution))
    execution = seen.first.last
    expect(seen.last.last).to equal(execution)
    expect(lantern_records(:span).map { |record| record[:name] }).to eq([ "stream each", "stream close" ])
    expect(lantern_records(:span).map { |record| record[:execution_id] }.uniq).to eq([ execution.id ])
    expect(lantern_records(:request).sole).to include(
      execution_id: execution.id, status_code: 206, path: "/stream"
    )
    expect(lantern_records(:request).sole[:duration]).to be >= 1_000
    expect(Lantern.execution).to be_nil

    body.close
    expect(close_calls).to eq(1)
    expect(lantern_records(:request).size).to eq(1)
  end

  it "finalizes an unconsumed streaming body when Rack closes it explicitly" do
    seen = []
    stream = Object.new
    stream.define_singleton_method(:each) { |&block| block.call("unused") }
    stream.define_singleton_method(:close) do
      seen << Lantern.execution
      Lantern.record(:span, name: "explicit close")
    end
    app = ->(_) { [ 200, { "Content-Type" => "text/plain" }, stream ] }

    _, _, body = described_class.new(app).call(env_for("http://customer.test/stream"))
    expect(lantern_records).to be_empty

    body.close
    body.close

    execution = seen.sole
    expect(execution).to be_a(Lantern::Execution)
    expect(lantern_records(:span).sole).to include(name: "explicit close", execution_id: execution.id)
    expect(lantern_records(:request).sole[:execution_id]).to eq(execution.id)
    expect(Lantern.execution).to be_nil
  end

  it "captures an enumeration failure and preserves it through hostile close and telemetry failures" do
    enumeration_error = Class.new(Exception)
    close_error = Class.new(Exception)
    original = enumeration_error.new("stream exploded")
    stream = Object.new
    close_calls = 0
    stream.define_singleton_method(:each) do |&block|
      block.call("first")
      raise original
    end
    stream.define_singleton_method(:close) do
      close_calls += 1
      raise close_error, "hostile close"
    end
    app = ->(_) { [ 200, { "Content-Type" => "text/plain" }, stream ] }
    _, _, body = described_class.new(app).call(env_for("http://customer.test/stream"))

    expect { body.each { |_| nil } }.to raise_error { |error| expect(error).to equal(original) }

    expect(close_calls).to eq(1)
    expect(lantern_records(:exception).sole).to include(message: "stream exploded", handled: false)
    request = lantern_records(:request).sole
    expect(lantern_records(:exception).sole[:execution_id]).to eq(request[:execution_id])
    expect(Lantern.execution).to be_nil

    body.close
    expect(close_calls).to eq(1)
    expect(lantern_records(:request).size).to eq(1)
  end

  it "runs a streaming body on another thread without leaking either thread's Current state" do
    seen = []
    stream = Object.new
    stream.define_singleton_method(:each) do |&block|
      seen << [ :each, Lantern.execution, Thread.current ]
      Lantern.record(:span, name: "cross-thread each")
      block.call("chunk")
    end
    stream.define_singleton_method(:close) do
      seen << [ :close, Lantern.execution, Thread.current ]
      Lantern.record(:span, name: "cross-thread close")
    end
    app = ->(_) { [ 200, { "Content-Type" => "text/plain" }, stream ] }

    _, _, body = described_class.new(app).call(env_for("http://customer.test/stream"))
    worker_parent = Lantern::Execution.new(source: :job, sampled: true)
    after = Queue.new
    worker = Thread.new do
      Lantern::Current.execution = worker_parent
      body.each { |_| nil }
      after << Lantern.execution
    ensure
      Lantern::Current.clear
    end
    worker.join

    request_execution = seen.first[1]
    expect(seen.map(&:first)).to eq(%i[each close])
    expect(seen.map { |entry| entry[1] }).to eq([ request_execution, request_execution ])
    expect(seen.map { |entry| entry[2] }).to eq([ worker, worker ])
    expect(after.pop).to equal(worker_parent)
    expect(lantern_records(:request).sole[:execution_id]).to eq(request_execution.id)
    expect(lantern_records(:span).map { |record| record[:execution_id] }.uniq).to eq([ request_execution.id ])
    expect(Lantern.execution).to be_nil
  end

  it "preserves an explicit body-close failure when telemetry finalization also fails" do
    close_error = Class.new(Exception)
    original = close_error.new("close exploded")
    stream = Object.new
    stream.define_singleton_method(:each) { |_| nil }
    stream.define_singleton_method(:close) { raise original }
    app = ->(_) { [ 200, { "Content-Type" => "text/plain" }, stream ] }
    _, _, body = described_class.new(app).call(env_for("http://customer.test/stream"))
    allow(Lantern).to receive(:finish_execution).and_raise(SignalException.new("TERM"))

    expect { body.close }.to raise_error { |error| expect(error).to equal(original) }
    expect(body).to be_closed
    expect(Lantern.execution).to be_nil
  end

  it "keeps Array responses on the immediate allocation-free lifecycle" do
    response_body = [ "ready" ]
    status, _, body = described_class.new(->(_) { [ 200, {}, response_body ] }).call(
      env_for("http://customer.test/eager")
    )

    expect(status).to eq(200)
    expect(body).to equal(response_body)
    expect(lantern_records(:request).sole[:path]).to eq("/eager")
  end

  it "wraps an Array subclass because its enumeration can still be lazy" do
    body_class = Class.new(Array) do
      def each
        Lantern.record(:span, name: "array subclass")
        yield "lazy"
      end
    end
    app = ->(_) { [ 200, {}, body_class.new ] }
    _, _, body = described_class.new(app).call(env_for("http://customer.test/lazy"))

    expect(lantern_records).to be_empty
    expect(body.each.to_a).to eq([ "lazy" ])
    expect(lantern_records(:span).sole[:name]).to eq("array subclass")
    expect(lantern_records(:request).size).to eq(1)
  end

  it "finishes the lifecycle when a server consumes a coercible body through to_ary" do
    close_calls = 0
    stream = Object.new
    stream.define_singleton_method(:to_ary) do
      Lantern.record(:span, name: "coerced body")
      [ "coerced" ]
    end
    stream.define_singleton_method(:each) { |_| raise "each should not run" }
    stream.define_singleton_method(:close) { close_calls += 1 }
    app = ->(_) { [ 200, {}, stream ] }
    _, _, body = described_class.new(app).call(env_for("http://customer.test/coerced"))

    expect(body.to_ary).to eq([ "coerced" ])
    expect(close_calls).to eq(1)
    expect(lantern_records(:span).sole[:name]).to eq("coerced body")
    expect(lantern_records(:request).size).to eq(1)
  end

  it "preserves Rack 3 call-only streaming body semantics" do
    writes = []
    close_calls = 0
    stream = Object.new
    stream.define_singleton_method(:call) do |io|
      Lantern.record(:span, name: "call body")
      io << "hello"
      :streamed
    end
    stream.define_singleton_method(:close) { close_calls += 1 }
    app = ->(_) { [ 200, { "Content-Type" => "text/plain" }, stream ] }

    _, _, body = described_class.new(app).call(env_for("http://customer.test/call-stream"))

    expect(body).to respond_to(:call)
    expect(body).not_to respond_to(:each)
    expect(body.call(writes)).to eq(:streamed)
    expect(writes).to eq([ "hello" ])
    expect(close_calls).to eq(1)
    expect(lantern_records(:span).sole[:execution_id]).to eq(lantern_records(:request).sole[:execution_id])

    body.close
    expect(close_calls).to eq(1)
  end

  it "does not report a call-style stream disconnect as an application exception" do
    disconnect = Errno::EPIPE.new("client disconnected")
    writes = 0
    downstream = Object.new
    downstream.define_singleton_method(:<<) do |_chunk|
      writes += 1
      raise disconnect if writes == 2

      self
    end
    stream = Object.new
    stream.define_singleton_method(:call) { |io| io << "first" << "second" }
    stream.define_singleton_method(:close) { nil }
    app = ->(_) { [ 200, {}, stream ] }
    _, _, body = described_class.new(app).call(env_for("http://customer.test/call-stream"))

    expect { body.call(downstream) }.to raise_error { |error| expect(error).to equal(disconnect) }
    expect(lantern_records(:request).size).to eq(1)
    expect(lantern_records(:exception)).to be_empty
  end

  it "passes a Rack::Lint round trip with a call-only streaming body" do
    stream = Object.new
    stream.define_singleton_method(:call) { |io| io << "linted" }
    stream.define_singleton_method(:close) { nil }
    app = ->(_) { [ 200, { "content-type" => "text/plain" }, stream ] }
    linted = Rack::Lint.new(described_class.new(app))

    status, _, body = linted.call(env_for("http://customer.test/call-stream"))
    io = StringIO.new
    io.define_singleton_method(:close_read) { nil }
    io.define_singleton_method(:close_write) { nil }
    body.call(io)
    body.close

    expect(status).to eq(200)
    expect(io.string).to eq("linted")
    expect(lantern_records(:request).size).to eq(1)
  end

  it "isolates a cross-thread request tenant and context from the consumer thread" do
    tenant_record = Class.new do
      def self.current_tenant
        Thread.current[:lantern_request_spec_tenant]
      end
    end
    stub_const("TenantRecord", tenant_record)
    stream_error = Class.new(StandardError)
    stream = Object.new
    stream.define_singleton_method(:each) do
      Lantern.context(stream_phase: "enumeration")
      raise stream_error, "stream failed"
    end
    stream.define_singleton_method(:close) { nil }
    app = lambda do |_|
      Thread.current[:lantern_request_spec_tenant] = "request-tenant"
      ActiveSupport::ExecutionContext.set(request_marker: "request-value")
      [ 200, {}, stream ]
    end

    _, _, body = described_class.new(app).call(env_for("http://customer.test/stream"))
    failure = Queue.new
    worker_context = Queue.new
    worker = Thread.new do
      Thread.current[:lantern_request_spec_tenant] = "worker-tenant"
      ActiveSupport::ExecutionContext.set(worker_secret: "must-not-leak")
      begin
        body.each { |_| nil }
      rescue StandardError => error
        failure << error
      ensure
        worker_context << ActiveSupport::ExecutionContext.to_h
        ActiveSupport::ExecutionContext.clear
        Thread.current[:lantern_request_spec_tenant] = nil
      end
    end
    worker.join

    expect(failure.pop).to be_a(stream_error)
    request = lantern_records(:request).sole
    exception = lantern_records(:exception).sole
    expect(request).to include(tenant: "request-tenant")
    expect(exception).to include(tenant: "request-tenant")
    expect(JSON.parse(request[:context])).to include(
      "request_marker" => "request-value", "stream_phase" => "enumeration"
    )
    expect(JSON.parse(exception[:context])).to include(
      "request_marker" => "request-value", "stream_phase" => "enumeration"
    )
    expect(exception[:context]).not_to include("worker_secret")
    expect(worker_context.pop).to include(worker_secret: "must-not-leak")
  ensure
    Thread.current[:lantern_request_spec_tenant] = nil
    ActiveSupport::ExecutionContext.clear
  end

  it "isolates request tenant and context on another fiber of the origin thread" do
    original_level = ActiveSupport::IsolatedExecutionState.isolation_level
    ActiveSupport::IsolatedExecutionState.isolation_level = :fiber
    tenant_record = Class.new do
      def self.current_tenant
        ActiveSupport::IsolatedExecutionState[:lantern_request_spec_tenant]
      end
    end
    stub_const("TenantRecord", tenant_record)
    stream = Object.new
    stream.define_singleton_method(:each) do |&block|
      Lantern.context(stream_phase: "enumeration")
      Lantern.record(:span, name: "fiber each")
      block.call("chunk")
    end
    stream.define_singleton_method(:close) { nil }
    app = lambda do |_|
      ActiveSupport::IsolatedExecutionState[:lantern_request_spec_tenant] = "request-tenant"
      ActiveSupport::ExecutionContext.set(request_marker: "request-value")
      [ 200, {}, stream ]
    end

    _, _, body = described_class.new(app).call(env_for("http://customer.test/fiber-stream"))
    consumer_context = Fiber.new do
      ActiveSupport::IsolatedExecutionState[:lantern_request_spec_tenant] = "consumer-tenant"
      ActiveSupport::ExecutionContext.set(consumer_secret: "must-not-leak")
      body.each { |_| nil }
      ActiveSupport::ExecutionContext.to_h
    end.resume

    request = lantern_records(:request).sole
    expect(lantern_records(:span).sole[:tenant]).to eq("request-tenant")
    expect(request[:tenant]).to eq("request-tenant")
    expect(JSON.parse(request[:context])).to include(
      "request_marker" => "request-value", "stream_phase" => "enumeration"
    )
    expect(request[:context]).not_to include("consumer_secret")
    expect(consumer_context).to include(consumer_secret: "must-not-leak")
  ensure
    ActiveSupport::IsolatedExecutionState.clear
    ActiveSupport::IsolatedExecutionState.isolation_level = original_level if original_level
  end

  it "does not report a downstream client disconnect as an application exception" do
    disconnect = Errno::EPIPE.new("client disconnected")
    stream = Object.new
    stream.define_singleton_method(:each) { |&block| block.call("chunk") }
    stream.define_singleton_method(:close) { nil }
    app = ->(_) { [ 200, {}, stream ] }
    _, _, body = described_class.new(app).call(env_for("http://customer.test/stream"))

    expect { body.each { raise disconnect } }.to raise_error { |error| expect(error).to equal(disconnect) }
    expect(lantern_records(:request).size).to eq(1)
    expect(lantern_records(:exception)).to be_empty
  end

  it "keeps Rack partial-hijack callback work inside the request lifecycle" do
    callback_execution = nil
    callback_stream = nil
    response_body = []
    hijack = proc do |stream|
      callback_execution = Lantern.execution
      callback_stream = stream
      stream.write("attached")
      Lantern.record(:span, name: "partial hijack")
      :attached
    end
    headers = { "rack.hijack" => hijack, "X-Stream" => "yes" }
    app = ->(_) { [ 200, headers, response_body ] }

    status, returned_headers, body = described_class.new(app).call(env_for("http://customer.test/hijack"))

    expect(status).to eq(200)
    expect(body).to be_a(described_class::EnumerableResponseBody)
    expect(returned_headers["X-Stream"]).to eq("yes")
    expect(lantern_records).to be_empty
    writes = []
    io = Object.new
    io.define_singleton_method(:write) { |chunk| writes << chunk }
    expect(returned_headers["rack.hijack"].call(io)).to eq(:attached)

    request = lantern_records(:request).sole
    expect(callback_execution).to be_a(Lantern::Execution)
    expect(callback_stream).to be_a(described_class::DownstreamStream)
    expect(writes).to eq([ "attached" ])
    expect(lantern_records(:span).sole).to include(name: "partial hijack", execution_id: request[:execution_id])
    expect(Lantern.execution).to be_nil
  end

  it "finalizes a partial hijack when the server closes the body without invoking its callback" do
    close_calls = 0
    response_body = Object.new
    response_body.define_singleton_method(:each) { |_| nil }
    response_body.define_singleton_method(:close) { close_calls += 1 }
    hijack = ->(_stream) { raise "must not be called" }
    app = ->(_) { [ 200, { "rack.hijack" => hijack }, response_body ] }

    _, returned_headers, body = described_class.new(app).call(env_for("http://customer.test/hijack"))
    expect(returned_headers["rack.hijack"]).not_to equal(hijack)
    expect(lantern_records).to be_empty

    body.close

    expect(close_calls).to eq(1)
    expect(lantern_records(:request).size).to eq(1)
    expect(Lantern.execution).to be_nil
  end

  it "does not report a partial-hijack stream disconnect as an application exception" do
    disconnect = Errno::EPIPE.new("client disconnected")
    downstream = Object.new
    downstream.define_singleton_method(:write) { |_chunk| raise disconnect }
    hijack = ->(stream) { stream.write("chunk") }
    app = ->(_) { [ 200, { "rack.hijack" => hijack }, [] ] }
    _, headers, body = described_class.new(app).call(env_for("http://customer.test/hijack"))

    expect { headers["rack.hijack"].call(downstream) }.to raise_error do |error|
      expect(error).to equal(disconnect)
    end
    expect(lantern_records(:request).size).to eq(1)
    expect(lantern_records(:exception)).to be_empty
    body.close
    expect(lantern_records(:request).size).to eq(1)
  end

  it "passes a Rack::Lint partial-hijack round trip with the shared lifecycle body" do
    hijack = ->(stream) { stream.write("hijacked") }
    app = ->(_) { [ 200, { "rack.hijack" => hijack }, [] ] }
    linted = Rack::Lint.new(described_class.new(app))
    rack_env = env_for("http://customer.test/hijack", headers: { "rack.hijack?" => true })

    status, headers, body = linted.call(rack_env)
    io = StringIO.new
    io.define_singleton_method(:close_read) { nil }
    io.define_singleton_method(:close_write) { nil }
    headers["rack.hijack"].call(io)
    body.close

    expect(status).to eq(200)
    expect(io.string).to eq("hijacked")
    expect(lantern_records(:request).size).to eq(1)
  end

  it "waits to finalize until active enumeration ends when another thread closes" do
    entered = Queue.new
    release = Queue.new
    close_calls = 0
    stream = Object.new
    stream.define_singleton_method(:each) do |&block|
      entered << true
      release.pop
      Lantern.record(:span, name: "after concurrent close")
      block.call("chunk")
    end
    stream.define_singleton_method(:close) { close_calls += 1 }
    app = ->(_) { [ 200, {}, stream ] }
    _, _, body = described_class.new(app).call(env_for("http://customer.test/stream"))

    consumer = Thread.new { body.each { |_| nil } }
    entered.pop
    closer = Thread.new { body.close }
    closer.join
    expect(lantern_records(:request)).to be_empty
    release << true
    consumer.join

    expect(lantern_records(:span).sole[:name]).to eq("after concurrent close")
    expect(lantern_records(:request).size).to eq(1)
    expect(close_calls).to eq(1)
    body.close
    expect(close_calls).to eq(1)
    expect(Lantern.execution).to be_nil
  ensure
    release << true if consumer&.alive?
    consumer&.join
    closer&.join
  end

  it "defers profiler cleanup until a streaming body finishes" do
    handle = Object.new
    Lantern.config.profile_sample = 1.0
    allow(Lantern::Profiler).to receive(:available?).and_return(true)
    allow(Lantern::Profiler).to receive(:start).and_return(handle)
    allow(Lantern::Profiler).to receive(:stop).and_return(nil)
    stream = Object.new
    stream.define_singleton_method(:each) { |_| nil }
    stream.define_singleton_method(:close) { nil }
    request_middleware = described_class.new(->(_) { [ 200, {}, stream ] })
    allow(request_middleware).to receive(:parent_fields).and_raise("parent construction failed")

    _, _, body = request_middleware.call(env_for("http://customer.test/stream"))

    expect(Lantern::Profiler).not_to have_received(:stop)
    body.close
    expect(Lantern::Profiler).to have_received(:stop).with(handle).once
    expect(Lantern.execution).to be_nil
  ensure
    Lantern.config.profile_sample = 0.0
  end

  it "discards an origin-thread profile before cross-thread body work" do
    handle = Object.new
    Lantern.config.profile_sample = 1.0
    allow(Lantern::Profiler).to receive(:available?).and_return(true)
    allow(Lantern::Profiler).to receive(:start).and_return(handle)
    allow(Lantern::Profiler).to receive(:stop).with(handle).and_return(nil)
    stream = Object.new
    stream.define_singleton_method(:each) do |&block|
      Lantern.record(:span, name: "cross-thread body")
      block.call("chunk")
    end
    stream.define_singleton_method(:close) { nil }
    request_middleware = described_class.new(->(_) { [ 200, {}, stream ] })
    _, _, body = request_middleware.call(env_for("http://customer.test/stream"))

    worker = Thread.new { body.each { |_| nil } }
    worker.join

    expect(Lantern::Profiler).to have_received(:stop).with(handle).once
    expect(lantern_records(:span).sole[:name]).to eq("cross-thread body")
    expect(lantern_records(:profile)).to be_empty
    expect(lantern_records(:request).size).to eq(1)
  ensure
    worker&.join
    Lantern.config.profile_sample = 0.0
  end

  it "finishes the request execution when the app leaves an inner execution current" do
    parent_execution = Lantern.start_execution(source: :job)
    request_execution = nil
    inner_execution = nil
    app = lambda do |env|
      request_execution = env.fetch("lantern.execution")
      inner_execution = Lantern.start_execution(source: :job, preview: "inner")
      [ 204, { "Content-Type" => "text/plain", "Content-Length" => "0" }, [] ]
    end

    status, = described_class.new(app).call(env_for("http://customer.test/widgets"))

    expect(status).to eq(204)
    request = lantern_records(:request).sole
    expect(request[:execution_id]).to eq(request_execution.id)
    expect(request[:execution_id]).not_to eq(inner_execution.id)
    expect(request[:execution_preview]).to eq("GET unmatched")
    expect(Lantern.execution).to equal(parent_execution)
  ensure
    Lantern::Current.clear
  end

  it "captures an app error on the request execution when the app leaves an inner execution current" do
    application_error = Class.new(StandardError)
    request_execution = nil
    inner_execution = nil
    app = lambda do |env|
      request_execution = env.fetch("lantern.execution")
      inner_execution = Lantern.start_execution(source: :job, preview: "inner")
      raise application_error, "original app error"
    end

    expect do
      described_class.new(app).call(env_for("http://customer.test/boom"))
    end.to raise_error(application_error, "original app error")

    exception = lantern_records(:exception).sole
    request = lantern_records(:request).sole
    expect(exception[:execution_id]).to eq(request_execution.id)
    expect(request[:execution_id]).to eq(request_execution.id)
    expect(exception[:execution_id]).not_to eq(inner_execution.id)
    expect(Lantern.execution).to be_nil
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
    expect(lantern_records(:request).sole).to include(status_code: 422, payload: nil, payload_truncated: true)
    expect(Lantern::Current.execution).to be_nil
  ensure
    Lantern.config.capture_request_payload = false
  end

  it "bounds huge cached opt-in payloads and reports the truncation" do
    Lantern.config.capture_request_payload = true
    params = { "items" => Array.new(Lantern::RequestPayload::MAX_NODES + 100) { "x" * 100 } }
    env = env_for("http://customer.test/api", method: "POST", headers: {
      "CONTENT_TYPE" => "application/json",
      "action_dispatch.request.request_parameters" => params
    })
    app = lambda do |_request_env|
      Lantern.report(RuntimeError.new("handled"))
      [ 422, { "Content-Type" => "application/json" }, [] ]
    end

    status, = described_class.new(app).call(env)

    expect(status).to eq(422)
    request = lantern_records(:request).sole
    expect(request[:payload_truncated]).to be(true)
    expect(JSON.generate(request[:payload]).bytesize).to be <= Lantern::RequestPayload::MAX_BYTES
    expect(request.dig(:payload, "items").size).to be < params["items"].size
  ensure
    Lantern.config.capture_request_payload = false
  end

  it "honors request-specific parameter filters after bounding cached params" do
    Lantern.config.capture_request_payload = true
    env = env_for("http://customer.test/api", method: "POST", headers: {
      "CONTENT_TYPE" => "application/json",
      "action_dispatch.parameter_filter" => [ :private_code ],
      "action_dispatch.request.request_parameters" => { "private_code" => "secret", "safe" => "shown" }
    })
    app = lambda do |_request_env|
      Lantern.report(RuntimeError.new("handled"))
      [ 422, { "Content-Type" => "application/json" }, [] ]
    end

    described_class.new(app).call(env)

    request = lantern_records(:request).sole
    expect(request[:payload]).to eq({ "private_code" => "[FILTERED]", "safe" => "shown" })
    expect(request[:payload_truncated]).to be_nil
  ensure
    Lantern.config.capture_request_payload = false
  end

  it "normalizes and bounds a prepopulated upload metadata cache" do
    invalid = "\xFF".b
    oversized = {
      name: invalid + ("n" * Lantern::UploadedFiles::MAX_NAME_BYTES),
      size: 2**100,
      content_type: invalid,
      error: invalid
    }
    env = env_for("http://customer.test/upload", method: "POST")
    app = lambda do |request_env|
      request_env["lantern.files"] = Array.new(Lantern::UploadedFiles::MAX_FILES + 10, oversized)
      [ 201, { "Content-Type" => "text/plain" }, [] ]
    end

    status, = described_class.new(app).call(env)

    expect(status).to eq(201)
    request = lantern_records(:request).sole
    expect(request[:files].size).to eq(Lantern::UploadedFiles::MAX_FILES)
    expect(request[:files].first).to include(size: Lantern::UploadedFiles::MAX_FILE_BYTES)
    expect(request[:files].first.values_at(:name, :content_type, :error)).to all(be_valid_encoding)
    expect { JSON.generate(request) }.not_to raise_error
    expect { Lantern::Transport::Http.new(Lantern.config).send(:encode, [ request ]) }.not_to raise_error
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
