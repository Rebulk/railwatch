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
    pending "bug: Backtrace.caller_location excludes any frame whose path includes the literal " \
            "substring \"/lantern/\", meant to skip the gem's own lib/lantern/ source. This repo's " \
            "own checkout directory is named \"lantern\", so every calling frame -- including this " \
            "spec file itself -- also matches that substring and gets excluded too, leaving :source " \
            "permanently nil for every outgoing_request record (same root cause already documented " \
            "in records/query_spec.rb)."

    Lantern.start_execution(source: :command, sample_kind: :commands)
    Net::HTTP.get(URI("http://example.test/widgets"))
    finish!

    req = lantern_records(:outgoing_request).sole
    expect(req[:source]).to include("outgoing_request_spec")
  end
end
