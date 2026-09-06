# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Nightrail::Patches::NetHttp" do
  def finish!
    Nightrail.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
  end

  it "omits the default port 443 from the url for an https request" do
    stub_request(:get, "https://secure.test/x").to_return(status: 200, body: "ok")
    Nightrail.start_execution(source: :command, sample_kind: :commands)
    Net::HTTP.get(URI("https://secure.test/x"))
    finish!

    expect(nightrail_records(:outgoing_request).sole[:url]).to eq("https://secure.test/x")
  end

  it "includes a non-default port in the url for an http request" do
    stub_request(:get, "http://example.test:8080/x").to_return(status: 200, body: "ok")
    Nightrail.start_execution(source: :command, sample_kind: :commands)
    Net::HTTP.get(URI("http://example.test:8080/x"))
    finish!

    expect(nightrail_records(:outgoing_request).sole[:url]).to eq("http://example.test:8080/x")
  end

  it "captures request_size and response_size as the exact byte counts of the POST body and response body" do
    stub_request(:post, "http://example.test/widgets").to_return(status: 201, body: "created")
    Nightrail.start_execution(source: :command, sample_kind: :commands)
    Net::HTTP.post(URI("http://example.test/widgets"), "a" * 37)
    finish!

    req = nightrail_records(:outgoing_request).sole
    expect(req[:request_size]).to eq(37)
    expect(req[:response_size]).to eq("created".bytesize)
  end

  describe "#nightrail_self_request?" do
    it "is true only when both host and port match config.ingest_url" do
      ingest = URI(Nightrail.config.ingest_url)
      same_host_and_port = Net::HTTP.new(ingest.host, ingest.port)
      same_host_different_port = Net::HTTP.new(ingest.host, 9999)

      expect(same_host_and_port.send(:nightrail_self_request?)).to be(true)
      expect(same_host_different_port.send(:nightrail_self_request?)).to be(false)
    end
  end

  describe "REENTRY guard" do
    it "leaves Thread.current[:nightrail_net_http] cleared after a request completes, so a later independent request is still instrumented" do
      Nightrail.start_execution(source: :command, sample_kind: :commands)
      Net::HTTP.get(URI("http://example.test/widgets"))
      expect(Thread.current[:nightrail_net_http]).to be_nil
      Net::HTTP.get(URI("http://example.test/widgets"))
      finish!

      expect(nightrail_records(:outgoing_request).size).to eq(2)
    end

    it "skips instrumentation entirely for a request made while the guard is already set" do
      Nightrail.start_execution(source: :command, sample_kind: :commands)
      Thread.current[:nightrail_net_http] = true
      begin
        Net::HTTP.get(URI("http://example.test/widgets"))
      ensure
        Thread.current[:nightrail_net_http] = nil
      end
      finish!

      expect(nightrail_records(:outgoing_request)).to be_empty
    end
  end
end
