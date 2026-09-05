# frozen_string_literal: true

require "spec_helper"

RSpec.describe "distributed tracing", type: :request do
  after do
    Lantern.config.propagate_traces = true
    Lantern.config.trace_propagation_hosts = nil
  end

  def traceparent_for(exe, flags:)
    "00-#{exe.trace_id.delete('-')}-#{exe.id.delete('-')[0, 16]}-#{flags}"
  end

  def in_execution(rate: 1.0)
    Lantern.config.sample[:commands] = rate
    exe = Lantern.start_execution(source: :command, sample_kind: :commands)
    yield exe
  ensure
    Lantern.finish_execution
  end

  def sent_traceparent(url = "http://example.test/x")
    header = nil
    expect(WebMock).to have_requested(:get, url).with { |req| header = req.headers["Traceparent"]; true }
    header
  end

  describe "outbound Net::HTTP" do
    it "sends a traceparent built from the current execution, flagged sampled" do
      exe = in_execution { |e| Net::HTTP.get(URI("http://example.test/x")); e }

      expect(sent_traceparent).to eq(traceparent_for(exe, flags: "01"))
    end

    it "flags the trace unsampled, but still propagates it, for a sampled-out execution" do
      exe = in_execution(rate: 0.0) { |e| Net::HTTP.get(URI("http://example.test/x")); e }

      expect(sent_traceparent).to eq(traceparent_for(exe, flags: "00"))
    end

    it "sends no traceparent when there is no execution" do
      Net::HTTP.get(URI("http://example.test/x"))

      expect(sent_traceparent).to be_nil
    end

    it "sends no traceparent when propagate_traces is off" do
      Lantern.config.propagate_traces = false
      in_execution { Net::HTTP.get(URI("http://example.test/x")) }

      expect(sent_traceparent).to be_nil
    end

    it "never overwrites a traceparent the app set itself" do
      app_header = "00-#{'c' * 32}-#{'d' * 16}-01"
      in_execution do
        uri = URI("http://example.test/x")
        req = Net::HTTP::Get.new(uri)
        req["traceparent"] = app_header
        Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
      end

      expect(sent_traceparent).to eq(app_header)
    end

    describe "trace_propagation_hosts" do
      before { stub_request(:get, "http://api.internal/x").to_return(status: 200, body: "hi") }

      it "propagates only to hosts matching a listed suffix" do
        Lantern.config.trace_propagation_hosts = [ ".internal" ]
        in_execution do
          Net::HTTP.get(URI("http://api.internal/x"))
          Net::HTTP.get(URI("http://example.test/x"))
        end

        expect(sent_traceparent("http://api.internal/x")).to be_a(String)
        expect(sent_traceparent).to be_nil
      end

      it "propagates to an exactly listed hostname" do
        Lantern.config.trace_propagation_hosts = [ "example.test" ]
        in_execution { Net::HTTP.get(URI("http://example.test/x")) }

        expect(sent_traceparent).to be_a(String)
      end
    end
  end

  describe "outbound Faraday" do
    before { stub_request(:get, "https://api.example.test/things").to_return(status: 204) }

    it "sends a traceparent from the connection middleware" do
      conn = ::Faraday.new("https://api.example.test") { |f| f.use Lantern::Faraday }
      exe = in_execution { |e| conn.get("/things"); e }

      expect(sent_traceparent("https://api.example.test/things")).to eq(traceparent_for(exe, flags: "01"))
    end

    it "never overwrites a traceparent the app set itself" do
      app_header = "00-#{'c' * 32}-#{'d' * 16}-01"
      conn = ::Faraday.new("https://api.example.test") { |f| f.use Lantern::Faraday }
      in_execution { conn.get("/things") { |req| req.headers["traceparent"] = app_header } }

      expect(sent_traceparent("https://api.example.test/things")).to eq(app_header)
    end

    it "sends no traceparent when the host is not on the allow list" do
      Lantern.config.trace_propagation_hosts = [ ".internal" ]
      conn = ::Faraday.new("https://api.example.test") { |f| f.use Lantern::Faraday }
      in_execution { conn.get("/things") }

      expect(sent_traceparent("https://api.example.test/things")).to be_nil
    end
  end

  describe "inbound traceparent" do
    let(:trace_id) { "a" * 32 }
    let(:parent_id) { "b" * 16 }

    it "adopts the upstream trace id and parent id" do
      get "/widgets", headers: { "traceparent" => "00-#{trace_id}-#{parent_id}-01" }

      req = lantern_records(:request).sole
      expect(req[:trace_id]).to eq(trace_id)
      expect(req[:parent_id]).to eq(parent_id)
    end

    it "keeps a head-sampled-out request whose upstream flagged the trace sampled" do
      Lantern.config.sample[:requests] = 0.0
      get "/widgets", headers: { "traceparent" => "00-#{trace_id}-#{parent_id}-01" }

      expect(lantern_records(:request).sole[:tail_sampled]).to be(true)
      expect(lantern_records(:query)).not_to be_empty
    end

    it "honours the head decision when the upstream flagged the trace unsampled" do
      Lantern.config.sample[:requests] = 0.0
      get "/widgets", headers: { "traceparent" => "00-#{trace_id}-#{parent_id}-00" }

      expect(lantern_records).to be_empty
    end

    it "ignores a malformed traceparent and starts its own trace" do
      get "/widgets", headers: { "traceparent" => "garbage" }

      req = lantern_records(:request).sole
      expect(req[:trace_id]).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      expect(req[:parent_id]).to be_nil
    end

    it "ignores a traceparent whose ids are the wrong length" do
      get "/widgets", headers: { "traceparent" => "00-#{'a' * 31}-#{parent_id}-01" }

      expect(lantern_records(:request).sole[:trace_id]).not_to eq("a" * 31)
    end

    it "ignores a traceparent with an all-zero trace id" do
      get "/widgets", headers: { "traceparent" => "00-#{'0' * 32}-#{parent_id}-01" }

      request = lantern_records(:request).sole
      expect(request[:trace_id]).not_to eq("0" * 32)
      expect(request[:parent_id]).to be_nil
    end

    it "ignores a traceparent with an all-zero parent id" do
      get "/widgets", headers: { "traceparent" => "00-#{trace_id}-#{'0' * 16}-01" }

      request = lantern_records(:request).sole
      expect(request[:trace_id]).not_to eq(trace_id)
      expect(request[:parent_id]).to be_nil
    end

    it "ignores the forbidden ff traceparent version" do
      get "/widgets", headers: { "traceparent" => "ff-#{trace_id}-#{parent_id}-01" }

      request = lantern_records(:request).sole
      expect(request[:trace_id]).not_to eq(trace_id)
      expect(request[:parent_id]).to be_nil
    end

    it "accepts opaque extension fields from a future traceparent version" do
      get "/widgets", headers: { "traceparent" => "01-#{trace_id}-#{parent_id}-03-vendor-data" }

      request = lantern_records(:request).sole
      expect(request).to include(trace_id: trace_id, parent_id: parent_id)
    end

    it "rejects extension fields on traceparent version 00" do
      get "/widgets", headers: { "traceparent" => "00-#{trace_id}-#{parent_id}-01-vendor-data" }

      request = lantern_records(:request).sole
      expect(request[:trace_id]).not_to eq(trace_id)
      expect(request[:parent_id]).to be_nil
    end

    it "rejects a future traceparent whose extension is not dash-delimited" do
      get "/widgets", headers: { "traceparent" => "01-#{trace_id}-#{parent_id}-01vendor-data" }

      request = lantern_records(:request).sole
      expect(request[:trace_id]).not_to eq(trace_id)
      expect(request[:parent_id]).to be_nil
    end
  end
end
