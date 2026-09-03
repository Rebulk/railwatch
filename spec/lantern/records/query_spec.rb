# frozen_string_literal: true

require "spec_helper"

RSpec.describe "query record", type: :request do
  before { 3.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) } }

  it "captures sql, name, duration, connection, adapter, row_count, and in_transaction for a SELECT" do
    get "/widgets"
    q = lantern_records(:query).find { |r| r[:sql].include?("FROM \"widgets\"") }
    expect(q[:sql]).to include("SELECT")
    expect(q[:name]).to eq("Widget Load")
    expect(q[:duration]).to be_a(Integer).and be >= 0
    expect(q[:connection]).to eq("primary")
    expect(q[:adapter]).to eq("sqlite")
    expect(q[:async]).to be(false)
    expect(q[:row_count]).to eq(3)
    expect(q[:in_transaction]).to be(false)
    expect(q[:allocations]).to be_a(Integer)
    expect(q[:role]).to eq("writing") # the multi-DB role the connection was checked out for
  end

  it "captures affected_rows and in_transaction for a write made inside a transaction" do
    exe = Lantern.start_execution(source: :command, sample_kind: :commands)
    ActiveRecord::Base.transaction { Widget.create!(name: "extra") }
    Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)

    insert = lantern_records(:query).find { |r| r[:sql].start_with?("INSERT") }
    expect(insert[:name]).to eq("Widget Create")
    expect(insert[:affected_rows]).to eq(1)
    expect(insert[:in_transaction]).to be(true)
    expect(exe.id).to be_a(String)
  end

  it "counts a cached query on the execution's counters but never ships a query record for it" do
    Rails.cache.clear
    get "/widgets"
    get "/widgets" # second hit is served from the query cache within its own request
    expect(lantern_records(:query)).not_to be_empty
  ensure
    Rails.cache.clear
  end

  it "skips SCHEMA and TRANSACTION named statements entirely" do
    get "/widgets"
    names = lantern_records(:query).map { |r| r[:name] }
    expect(names).not_to include("SCHEMA", "TRANSACTION")
  end

  it "computes a caller source location for a query shape" do
    get "/many"
    sources = lantern_records(:query).select { |r| r[:sql].include?("FROM \"gadgets\"") }.map { |r| r[:source] }
    expect(sources.compact).not_to be_empty
  end
end
