# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Railwatch::MonitoringHealth::SqliteStorage do
  around do |example|
    Dir.mktmpdir("railwatch-health-storage") do |directory|
      @path = File.join(directory, "telemetry.sqlite3")
      File.binwrite(@path, "a" * 1_000)
      File.binwrite("#{@path}-wal", "b" * 600)
      example.run
    end
  end

  let(:connection) do
    double("SQLite metadata connection", adapter_name: "SQLite").tap do |connection|
      { "page_size" => 4_096, "page_count" => 10, "freelist_count" => 3, "auto_vacuum" => 2, "journal_mode" => "wal" }.each do |name, value|
        allow(connection).to receive(:select_value).with("PRAGMA #{name}").and_return(value)
      end
      allow(connection).to receive(:select_all).with("PRAGMA database_list").and_return([ { "name" => "main", "file" => @path } ])
    end
  end

  it "uses physical data plus WAL for budget thresholds and keeps reusable pages separate" do
    below = described_class.new(connection, budget_bytes: 2_001).to_h
    warning = described_class.new(connection, budget_bytes: 2_000).to_h
    reached = described_class.new(connection, budget_bytes: 1_600).to_h

    expect(below[:budget][:status]).to eq("ok")
    expect(warning[:budget]).to include(status: "warning", used_bytes: 1_600, percent: 80.0)
    expect(reached[:budget]).to include(status: "critical", percent: 100.0)
    expect(reached).to include(data_bytes: 1_000, wal_bytes: 600, allocated_bytes: 40_960,
                              freelist_bytes: 12_288, active_bytes: 28_672, auto_vacuum: "incremental")
    expect(reached.to_json).not_to include(@path)
  end

  it "treats a missing WAL as zero and an unreadable data file as unknown" do
    File.unlink("#{@path}-wal")
    expect(described_class.new(connection).to_h).to include(wal_bytes: 0, physical_bytes: 1_000)

    File.unlink(@path)
    snapshot = described_class.new(connection, budget_bytes: 2_000).to_h
    expect(snapshot).to include(status: "unknown", data_bytes: nil, physical_bytes: nil)
    expect(snapshot[:budget]).to include(status: "unknown", percent: nil)
  end

  it "reports in-memory file sizes as unavailable while retaining SQLite page facts" do
    allow(connection).to receive(:select_all).with("PRAGMA database_list").and_return([ { "name" => "main", "file" => "" } ])

    snapshot = described_class.new(connection).to_h

    expect(snapshot).to include(in_memory: true, data_bytes: nil, wal_bytes: nil, physical_bytes: nil, allocated_bytes: 40_960)
    expect(snapshot[:budget][:status]).to eq("not_applicable")
  end
end
