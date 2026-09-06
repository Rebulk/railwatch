# frozen_string_literal: true

require "spec_helper"

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

    expect(lantern_records(:request).map { |request| request[:files] }).to eq([ [], [] ])
  end

  describe "lazy response bodies" do
    def body_middleware(body, &application)
      described_class.new(lambda do |env|
        application&.call(env)
        [ 200, { "Content-Type" => "text/plain" }, body ]
      end)
    end

    it "leaves arrays and buffered Rails response bodies on the eager path" do
      array = [ "ready" ]
      rails_body = ActionDispatch::Response.new(200, {}, [ "ready" ]).to_a.last

      returned_array = body_middleware(array).call(env_for("http://customer.test/array")).last
      returned_rails_body = body_middleware(rails_body).call(env_for("http://customer.test/rails-body")).last

      expect(returned_array).to be(array)
      expect(returned_rails_body).to be(rails_body)
      expect(lantern_records(:request).map { |record| record[:path] }).to contain_exactly("/array", "/rails-body")
    end

    it "wraps a real Rails response body whose stream is lazy" do
      stream = Object.new
      stream.define_singleton_method(:each) do |&block|
        Lantern.record(:span, name: "rails.stream")
        block.call("chunk")
      end
      rails_body = ActionDispatch::Response.new(200, {}, stream).to_a.last

      returned = body_middleware(rails_body).call(env_for("http://customer.test/rails-stream")).last

      expect(returned).to be_a(described_class::ResponseBody)
      expect(lantern_records).to be_empty
      expect(returned.each.to_a).to eq([ "chunk" ])
      expect(lantern_records(:span).sole[:name]).to eq("rails.stream")
      expect(lantern_records(:request).sole[:path]).to eq("/rails-stream")
    end

    it "keeps a real Rails call-only streaming body inside the request execution" do
      stream = Object.new
      closed = 0
      stream.define_singleton_method(:call) do |output|
        Lantern.record(:span, name: "rails.call-stream")
        output << "one" << "two"
      end
      stream.define_singleton_method(:close) { closed += 1 }
      rails_body = ActionDispatch::Response.new(200, {}, stream).to_a.last
      returned = body_middleware(rails_body).call(env_for("http://customer.test/rails-call-stream")).last
      output = StringIO.new

      expect(returned).to be_a(described_class::StreamingResponseBody)
      expect(returned).to respond_to(:call)
      expect(returned).not_to respond_to(:each)
      expect(lantern_records).to be_empty

      returned.call(output)

      expect(output.string).to eq("onetwo")
      expect(closed).to eq(1)
      expect(lantern_records(:span).sole[:name]).to eq("rails.call-stream")
      expect(lantern_records(:request).sole[:path]).to eq("/rails-call-stream")
    end

    it "reports a call-only application failure and preserves its exact exception" do
      error = RuntimeError.new("call stream failed")
      stream = Object.new
      stream.define_singleton_method(:call) { |_output| raise error }
      returned = body_middleware(stream).call(env_for("http://customer.test/failing-call-stream")).last

      expect { returned.call(StringIO.new) }.to raise_error { |raised| expect(raised).to be(error) }

      request = lantern_records(:request).sole
      expect(lantern_records(:exception).sole).to include(
        message: "call stream failed", handled: false, execution_id: request[:execution_id])
    end

    it "does not report a downstream call-stream failure and restores the consumer Current" do
      error = IOError.new("client disconnected")
      stream = Object.new
      stream.define_singleton_method(:call) { |output| output.write("chunk") }
      returned = body_middleware(stream).call(env_for("http://customer.test/call-disconnect")).last
      output = StringIO.new
      output.define_singleton_method(:write) { |*| raise error }
      prior = Lantern::Execution.new(source: :command, sampled: true)

      raised, restored = Thread.new do
        Lantern::Current.execution = prior
        begin
          returned.call(output)
        rescue Exception => caught # rubocop:disable Lint/RescueException
          [ caught, Lantern.execution ]
        ensure
          Lantern::Current.clear
        end
      end.value

      expect(raised).to be(error)
      expect(restored).to be(prior)
      expect(lantern_records(:exception)).to be_empty
      expect(lantern_records(:request).count).to eq(1)
      expect(Lantern.execution).to be_nil
    end

    it "keeps chained stream operations inside the downstream boundary" do
      error = IOError.new("client disconnected")
      stream = Object.new
      stream.define_singleton_method(:call) { |output| output.flush.write("chunk") }
      returned = body_middleware(stream).call(env_for("http://customer.test/flush-chain")).last
      output = StringIO.new
      output.define_singleton_method(:write) { |*| raise error }

      expect { returned.call(output) }.to raise_error { |raised| expect(raised).to be(error) }
      expect(lantern_records(:exception)).to be_empty
      expect(lantern_records(:request).count).to eq(1)
    end

    it "preserves path bodies for Rack::Sendfile" do
      body = Object.new
      body.define_singleton_method(:each) { |&block| block.call("file") }
      body.define_singleton_method(:to_path) { "/tmp/example" }

      returned = body_middleware(body).call(env_for("http://customer.test/file")).last

      expect(returned).to be(body)
      expect(returned.to_path).to eq("/tmp/example")
      expect(lantern_records(:request).sole[:path]).to eq("/file")
    end

    it "keeps enumeration and close inside the request execution" do
      body = Object.new
      close_calls = 0
      body.define_singleton_method(:each) do |&block|
        Lantern.record(:span, name: "stream.each")
        block.call("one")
        block.call("two")
      end
      body.define_singleton_method(:close) do
        close_calls += 1
        Lantern.record(:span, name: "stream.close")
      end

      returned = body_middleware(body).call(env_for("http://customer.test/stream")).last
      sleep 0.01

      expect(Lantern.execution).to be_nil
      expect(lantern_records).to be_empty
      expect(returned.each.to_a).to eq(%w[one two])
      request = lantern_records(:request).sole
      spans = lantern_records(:span)
      expect(close_calls).to eq(1)
      expect(request[:duration]).to be >= 8_000
      expect(spans.map { |span| span[:name] }).to contain_exactly("stream.each", "stream.close")
      expect(spans.map { |span| span[:execution_id] }.uniq).to eq([ request[:execution_id] ])
    end

    it "finalizes once when explicitly closed more than once" do
      body = Object.new
      close_calls = 0
      body.define_singleton_method(:each) { |&block| block.call("unused") }
      body.define_singleton_method(:close) { close_calls += 1 }
      returned = body_middleware(body).call(env_for("http://customer.test/close")).last

      returned.close
      returned.close

      expect(returned).to be_closed
      expect(close_calls).to eq(1)
      expect(lantern_records(:request).count).to eq(1)
    end

    it "reports an enumeration failure and preserves the exact exception" do
      error = RuntimeError.new("stream failed")
      body = Object.new
      body.define_singleton_method(:each) { raise error }

      returned = body_middleware(body).call(env_for("http://customer.test/failing-stream")).last

      expect { returned.each { |_chunk| } }.to raise_error { |raised| expect(raised).to be(error) }
      request = lantern_records(:request).sole
      exception = lantern_records(:exception).sole
      expect(exception).to include(message: "stream failed", handled: false,
                                   execution_id: request[:execution_id])
    end

    it "does not report an exception raised by the downstream consumer" do
      error = IOError.new("client disconnected")
      body = Object.new
      body.define_singleton_method(:each) { |&block| block.call("chunk") }
      returned = body_middleware(body).call(env_for("http://customer.test/disconnect")).last

      expect { returned.each { raise error } }.to raise_error { |raised| expect(raised).to be(error) }

      expect(lantern_records(:exception)).to be_empty
      expect(lantern_records(:request).count).to eq(1)
    end

    it "reports a close failure unless enumeration already failed" do
      close_error = RuntimeError.new("close failed")
      body = Object.new
      body.define_singleton_method(:each) { |&block| block.call("chunk") }
      body.define_singleton_method(:close) { raise close_error }
      returned = body_middleware(body).call(env_for("http://customer.test/close-failed")).last

      expect { returned.each.to_a }.to raise_error { |raised| expect(raised).to be(close_error) }
      expect(lantern_records(:exception).sole[:message]).to eq("close failed")

      primary = RuntimeError.new("enumeration failed")
      secondary = RuntimeError.new("secondary close failed")
      other = Object.new
      other.define_singleton_method(:each) { raise primary }
      other.define_singleton_method(:close) { raise secondary }
      returned = body_middleware(other).call(env_for("http://customer.test/two-failures")).last

      expect { returned.each.to_a }.to raise_error { |raised| expect(raised).to be(primary) }
      expect(lantern_records(:exception).map { |record| record[:message] }).to contain_exactly("close failed", "enumeration failed")
      expect(lantern_records(:request).count).to eq(2)
    end

    it "restores Current when another thread consumes the body" do
      body = Object.new
      body.define_singleton_method(:each) do |&block|
        Lantern.record(:span, name: "cross-thread")
        block.call("chunk")
      end
      app = body_middleware(body) { Lantern.context(request_context: "retained") }
      returned = app.call(env_for("http://customer.test/cross-thread")).last
      prior = Lantern::Execution.new(source: :command, sampled: true)

      chunks, restored = Thread.new do
        Lantern::Current.execution = prior
        Lantern.context(unrelated_consumer: true)
        [ returned.each.to_a, Lantern.execution ]
      ensure
        Lantern::Current.clear
        ActiveSupport::ExecutionContext.clear
        Rails.event.clear_context
      end.value

      request = lantern_records(:request).sole
      expect(chunks).to eq([ "chunk" ])
      expect(restored).to be(prior)
      expect(lantern_records(:span).sole[:execution_id]).to eq(request[:execution_id])
      expect(JSON.parse(request[:context])).to include("request_context" => "retained")
      expect(JSON.parse(request[:context])).not_to include("unrelated_consumer")
      expect(Lantern.execution).to be_nil
    ensure
      ActiveSupport::ExecutionContext.clear
      Rails.event.clear_context
    end

    it "does not import consumer context into a cross-thread body exception" do
      error = RuntimeError.new("body failed")
      body = Object.new
      body.define_singleton_method(:each) { raise error }
      app = body_middleware(body) { Lantern.context(request_context: "retained") }
      returned = app.call(env_for("http://customer.test/cross-thread-failure")).last

      raised, restored_context = Thread.new do
        Lantern.context(unrelated_consumer: "private")
        begin
          returned.each { |_chunk| }
        rescue Exception => caught # rubocop:disable Lint/RescueException
          [ caught, Lantern::Context.current ]
        ensure
          Lantern::Current.clear
          ActiveSupport::ExecutionContext.clear
          Rails.event.clear_context
        end
      end.value

      expect(raised).to be(error)
      expect(restored_context).to include(unrelated_consumer: "private")
      context = JSON.parse(lantern_records(:exception).sole[:context])
      expect(context).to include("request_context" => "retained")
      expect(context).not_to include("unrelated_consumer")
    ensure
      ActiveSupport::ExecutionContext.clear
      Rails.event.clear_context
    end

    it "does not mistake a reused carrier for the originating logical context" do
      body = Object.new
      body.define_singleton_method(:each) { |&block| block.call("chunk") }
      app = body_middleware(body) { Lantern.context(request_context: "original") }
      returned = app.call(env_for("http://customer.test/deferred")).last

      ActiveSupport::ExecutionContext.clear
      Rails.event.clear_context
      Lantern.context(unrelated_consumer: "private")
      returned.each.to_a

      context = JSON.parse(lantern_records(:request).sole[:context])
      expect(context).to include("request_context" => "original")
      expect(context).not_to include("unrelated_consumer")
      expect(Lantern::Context.current).to include(unrelated_consumer: "private")
    ensure
      ActiveSupport::ExecutionContext.clear
      Rails.event.clear_context
      Lantern::Current.clear
    end

    it "restores every consumer context when an after-change callback fails" do
      body_error = RuntimeError.new("body failed")
      fail_restoration = false
      body = Object.new
      body.define_singleton_method(:each) do
        fail_restoration = true
        raise body_error
      end
      app = body_middleware(body) { Lantern.context(origin: "request") }
      returned = app.call(env_for("http://customer.test/callback-failure")).last

      ActiveSupport::ExecutionContext.clear
      Rails.event.clear_context
      Lantern.context(consumer: "private")
      consumer_record = ActiveSupport::IsolatedExecutionState[Lantern::Context::EXECUTION_CONTEXT_KEY]
      callbacks = ActiveSupport::ExecutionContext.instance_variable_get(:@after_change_callbacks)
      callback = proc do
        if fail_restoration && ActiveSupport::IsolatedExecutionState[Lantern::Context::EXECUTION_CONTEXT_KEY].equal?(consumer_record)
          raise "after_change failed"
        end
      end
      callbacks << callback

      expect { returned.each { |_chunk| } }.to raise_error { |raised| expect(raised).to be(body_error) }
      expect(ActiveSupport::ExecutionContext.to_h).to include(consumer: "private")
      expect(Rails.event.context).to include(consumer: "private")
    ensure
      fail_restoration = false
      callbacks&.delete(callback)
      ActiveSupport::ExecutionContext.clear
      Rails.event.clear_context
      Lantern::Current.clear
    end

    it "resolves the request identity before detaching from the Rails context" do
      stub_const("TenantRecord", Class.new do
        def self.current_tenant = "acme"
      end)
      user = Struct.new(:id, :name, :email).new(7, "Ada", "ada@example.test")
      warden = Object.new
      warden.define_singleton_method(:user) { user }
      env = env_for("http://customer.test/identity")
      env["warden"] = warden
      body = Object.new
      body.define_singleton_method(:each) { |&block| block.call("chunk") }

      returned = body_middleware(body).call(env).last
      returned.each.to_a

      request = lantern_records(:request).sole
      expect(request).to include(user: "acme:7", tenant: "acme")
      expect(lantern_records(:user).sole).to include(id: "acme:7", name: "Ada")
    end

    it "retains the serialized request context after the inner body clears it" do
      body = Object.new
      body.define_singleton_method(:each) do |&block|
        Lantern.context(stream_phase: "each")
        block.call("chunk")
      end
      body.define_singleton_method(:close) do
        ActiveSupport::ExecutionContext.clear
        Rails.event.clear_context
      end
      app = body_middleware(body) { Lantern.context(stream_id: "abc123") }

      returned = app.call(env_for("http://customer.test/context")).last
      returned.each.to_a

      expect(JSON.parse(lantern_records(:request).sole[:context])).to include(
        "stream_id" => "abc123", "stream_phase" => "each")
    ensure
      ActiveSupport::ExecutionContext.clear
      Rails.event.clear_context
    end
  end
end
