# frozen_string_literal: true

require "spec_helper"

RSpec.describe "cache_event record" do
  before { Rails.cache.clear }
  after { Rails.cache.clear }

  def run_in_execution
    Nightrail.start_execution(source: :command, sample_kind: :commands)
    yield
    Nightrail.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
  end

  it "reports type write with ttl from expires_in, and type write with ttl 0 when none given" do
    run_in_execution do
      Rails.cache.write("a", 1, expires_in: 60)
      Rails.cache.write("b", 2)
    end

    events = nightrail_records(:cache_event)
    a = events.find { |e| e[:key] == "a" }
    b = events.find { |e| e[:key] == "b" }
    expect(a).to include(type: "write", ttl: 60, store: "MemoryStore")
    expect(b).to include(type: "write", ttl: 0)
  end

  it "reports type read_multi with a hits count of the keys actually found" do
    run_in_execution do
      Rails.cache.write("a", 1)
      Rails.cache.write("b", 2)
      Rails.cache.read_multi("a", "b", "c")
    end

    multi = nightrail_records(:cache_event).find { |e| e[:type] == "read_multi" }
    expect(multi[:hits]).to eq(2)
  end

  it "reports generate then write for a fetch miss, and fetch_hit for a subsequent hit -- skipping the inner cache_read entirely" do
    run_in_execution { Rails.cache.fetch("shape") { "value" } }
    miss_types = nightrail_records(:cache_event).map { |e| e[:type] }
    expect(miss_types).to eq(%w[generate write])

    nightrail_transport.batches.clear
    run_in_execution { Rails.cache.fetch("shape") { "value" } }
    hit_types = nightrail_records(:cache_event).map { |e| e[:type] }
    expect(hit_types).to eq(%w[hit])
  end

  it "rejects a default vendor key prefix (rack::attack) by default" do
    run_in_execution { Rails.cache.write("rack::attack:127.0.0.1", 1) }
    expect(nightrail_records(:cache_event)).to be_empty
  end

  it "ships the default vendor key once capture_default_vendor_cache_keys is enabled" do
    Nightrail.config.capture_default_vendor_cache_keys = true
    run_in_execution { Rails.cache.write("rack::attack:127.0.0.1", 1) }
    expect(nightrail_records(:cache_event).map { |e| e[:key] }).to include("rack::attack:127.0.0.1")
  ensure
    Nightrail.config.capture_default_vendor_cache_keys = false
  end

  it "reports type fail when the store raises during a write" do
    store = Rails.cache
    allow(store).to receive(:write_entry).and_raise(IOError, "disk full")
    run_in_execution do
      begin
        store.write("broken", 1)
      rescue IOError
        nil
      end
    end

    expect(nightrail_records(:cache_event).find { |e| e[:key] == "broken" }).to include(type: "fail")
  end
end
