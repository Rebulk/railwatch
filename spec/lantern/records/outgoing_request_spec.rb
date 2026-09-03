# frozen_string_literal: true

require "spec_helper"

RSpec.describe "outgoing_request record" do
  def finish!
    Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
  end

  it "captures host, method, url without the query string, duration, status_code, and response_size for a successful GET" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Net::HTTP.get(URI("http://example.test/widgets?secret=1"))
    finish!

    req = lantern_records(:outgoing_request).sole
    expect(req[:host]).to eq("example.test")
    expect(req[:method]).to eq("GET")
    expect(req[:url]).to eq("http://example.test/widgets") # query string stripped
    expect(req[:duration]).to be_a(Integer).and be >= 0
    expect(req[:status_code]).to eq(200)
    expect(req[:request_size]).to eq(0) # GET has no body
    expect(req[:response_size]).to eq(2) # stubbed body "hi" / Content-Length: 2
    expect(req[:error]).to be_nil
  end

  it "captures the error message and status_code 0 when the connection is refused" do
    stub_request(:get, "http://broken.test/x").to_raise(Errno::ECONNREFUSED)

    Lantern.start_execution(source: :command, sample_kind: :commands)
    expect { Net::HTTP.get(URI("http://broken.test/x")) }.to raise_error(Errno::ECONNREFUSED)
    finish!

    req = lantern_records(:outgoing_request).sole
    expect(req[:status_code]).to eq(0)
    expect(req[:error]).to eq("Errno::ECONNREFUSED: Connection refused - Exception from WebMock")
  end

  it "does not ship a record for a request to the ingest host itself" do
    stub_request(:get, "http://lantern.test/ingest").to_return(status: 200, body: "ok")

    Lantern.start_execution(source: :command, sample_kind: :commands)
    Net::HTTP.get(URI("http://lantern.test/ingest"))
    finish!

    expect(lantern_records(:outgoing_request)).to be_empty
  end

  it "records exactly once for a single request made via Net::HTTP.start, not doubled by the reentry guard" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    uri = URI("http://example.test/widgets")
    Net::HTTP.start(uri.host, uri.port) { |http| http.get(uri.path) }
    finish!

    expect(lantern_records(:outgoing_request).size).to eq(1)
  end

  it "instrument_outgoing records an outgoing_request for a non-Net::HTTP client result that responds to #status" do
    fake_response = Struct.new(:status).new(204)

    Lantern.start_execution(source: :command, sample_kind: :commands)
    result = Lantern.instrument_outgoing("GET", "http://custom-adapter.test/x") { fake_response }
    finish!

    expect(result).to equal(fake_response) # returns the yielded value untouched
    req = lantern_records(:outgoing_request).sole
    expect(req[:host]).to eq("custom-adapter.test")
    expect(req[:method]).to eq("GET")
    expect(req[:url]).to eq("http://custom-adapter.test/x")
    expect(req[:status_code]).to eq(204)
  end

  it "instrument_outgoing does not record anything when the yielded result has no #status" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    result = Lantern.instrument_outgoing("GET", "http://custom-adapter.test/x") { "plain string" }
    finish!

    expect(result).to eq("plain string")
    expect(lantern_records(:outgoing_request)).to be_empty
  end

  it "computes a caller source location for an outgoing request" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Net::HTTP.get(URI("http://example.test/widgets"))
    finish!

    req = lantern_records(:outgoing_request).sole
    expect(req[:source]).to include("outgoing_request_spec")
  end

  describe "response_body (capture_response_body_on_error)" do
    def fetch(url)
      Lantern.start_execution(source: :command, sample_kind: :commands)
      Net::HTTP.get(URI(url))
      finish!
      lantern_records(:outgoing_request).sole
    end

    def faraday_get(path, middleware: nil)
      conn = ::Faraday.new("http://example.test") do |f|
        f.use Lantern::Faraday
        f.response(middleware) if middleware
      end
      Lantern.start_execution(source: :command, sample_kind: :commands)
      yield conn, path
      finish!
      lantern_records(:outgoing_request).sole
    end

    it "is nil when the option is off, even for a 500" do
      stub_request(:get, "http://example.test/boom").to_return(status: 500, body: "upstream exploded")

      expect(fetch("http://example.test/boom")[:response_body]).to be_nil
    end

    context "when the option is on" do
      around do |example|
        Lantern.config.capture_response_body_on_error = true
        example.run
      ensure
        Lantern.config.capture_response_body_on_error = false
      end

      it "captures the body of a 500" do
        stub_request(:get, "http://example.test/boom").to_return(status: 500, body: "upstream exploded")

        expect(fetch("http://example.test/boom")[:response_body]).to eq("upstream exploded")
      end

      it "captures the body of a 404" do
        stub_request(:get, "http://example.test/gone").to_return(status: 404, body: "no such widget")

        expect(fetch("http://example.test/gone")[:response_body]).to eq("no such widget")
      end

      it "does not capture the body of a successful response" do
        expect(fetch("http://example.test/widgets")[:response_body]).to be_nil
      end

      it "is nil when the request raised before any response came back" do
        stub_request(:get, "http://broken.test/x").to_raise(Errno::ECONNREFUSED)

        Lantern.start_execution(source: :command, sample_kind: :commands)
        expect { Net::HTTP.get(URI("http://broken.test/x")) }.to raise_error(Errno::ECONNREFUSED)
        finish!

        req = lantern_records(:outgoing_request).sole
        expect(req[:error]).to include("Errno::ECONNREFUSED")
        expect(req[:response_body]).to be_nil
      end

      it "redacts a JSON error body through the same parameter filter as request params" do
        stub_request(:get, "http://example.test/boom")
          .to_return(status: 422, body: '{"password":"hunter2","error":"invalid"}')

        expect(fetch("http://example.test/boom")[:response_body])
          .to eq('{"password":"[FILTERED]","error":"invalid"}')
      end

      it "stores a non-JSON error body as it arrived" do
        stub_request(:get, "http://example.test/boom").to_return(status: 502, body: "<html>bad gateway</html>")

        expect(fetch("http://example.test/boom")[:response_body]).to eq("<html>bad gateway</html>")
      end

      it "keeps at most 4 KiB of the body" do
        stub_request(:get, "http://example.test/boom").to_return(status: 500, body: "x" * 10_000)

        expect(fetch("http://example.test/boom")[:response_body].length).to eq(4096)
      end

      it "captures the body on the Faraday path too" do
        stub_request(:get, "http://example.test/boom").to_return(status: 500, body: '{"error":"nope"}')

        req = faraday_get("/boom") { |conn, path| conn.get(path) }
        expect(req[:status_code]).to eq(500)
        expect(req[:response_body]).to eq('{"error":"nope"}')
      end

      it "captures the body on the Faraday path when raise_error turns the 500 into an exception" do
        stub_request(:get, "http://example.test/boom").to_return(status: 500, body: "upstream exploded")

        req = faraday_get("/boom", middleware: :raise_error) do |conn, path|
          expect { conn.get(path) }.to raise_error(Faraday::ServerError)
        end
        expect(req[:error]).to include("Faraday::ServerError")
        expect(req[:response_body]).to eq("upstream exploded")
      end

      it "never files a Faraday request payload as a response body when the connection fails" do
        stub_request(:post, "http://example.test/widgets").to_raise(Faraday::ConnectionFailed.new("down"))

        req = faraday_get("/widgets") do |conn, path|
          expect { conn.post(path, "name=secret") }.to raise_error(Faraday::ConnectionFailed)
        end
        expect(req[:error]).to include("down")
        expect(req[:response_body]).to be_nil
      end

      it "does not capture the body of a successful Faraday response" do
        stub_request(:get, "http://example.test/ok").to_return(status: 200, body: "fine")

        expect(faraday_get("/ok") { |conn, path| conn.get(path) }[:response_body]).to be_nil
      end
    end
  end
end
