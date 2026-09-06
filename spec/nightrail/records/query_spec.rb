# frozen_string_literal: true

require "spec_helper"

RSpec.describe "query record", type: :request do
  before { 3.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) } }

  after { Nightrail.config.capture_sql_values = false }

  it "does not capture SQL literal values by default" do
    sql = "SELECT 'private-customer@example.test' AS secret"
    Nightrail.start_execution(source: :command, sample_kind: :commands)
    ActiveRecord::Base.connection.select_all(sql)
    Nightrail.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)

    q = nightrail_records(:query).find { |r| r[:sql].start_with?("SELECT") }
    expect(q[:sql]).to eq("SELECT ? AS secret")
    expect(q[:sql]).not_to include("private-customer@example.test")
    expect(q).not_to have_key(:binds)
  end

  it "does not capture SQLite's ambiguous double-quoted string values" do
    sql = 'SELECT "private-dqs@example.test" AS secret'
    Nightrail.start_execution(source: :command, sample_kind: :commands)
    # Rails disables SQLite's legacy DQS fallback where supported, but older
    # deployments can execute this as a string. The failed-query notification
    # must be private too.
    expect { ActiveRecord::Base.connection.select_all(sql) }.to raise_error(ActiveRecord::StatementInvalid)
    Nightrail.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)

    q = nightrail_records(:query).find { |r| r[:sql].start_with?("SELECT") }
    expect(q[:sql]).to eq("SELECT ? AS secret")
    expect(q[:sql]).not_to include("private-dqs@example.test")
  end

  it "captures raw SQL only after an explicit opt-in" do
    Nightrail.config.capture_sql_values = true
    sql = "SELECT 'private-customer@example.test' AS secret"
    Nightrail.start_execution(source: :command, sample_kind: :commands)
    ActiveRecord::Base.connection.select_all(sql)
    Nightrail.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)

    q = nightrail_records(:query).find { |r| r[:sql].start_with?("SELECT") }
    expect(q[:sql]).to eq(sql)
    expect(q).not_to have_key(:binds)
  end

  it "bounds and repairs encoding in explicitly captured raw SQL" do
    Nightrail.config.capture_sql_values = true
    sql = ("SELECT ".b + "\xFF".b + ("x" * 20_000).b).force_encoding(Encoding::UTF_8)
    Nightrail.start_execution(source: :command, sample_kind: :commands)
    ActiveSupport::Notifications.instrument("sql.active_record", sql: sql, binds: [], name: "Raw SQL")
    Nightrail.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)

    q = nightrail_records(:query).find { |r| r[:name] == "Raw SQL" }
    expect(q[:sql]).to be_valid_encoding
    expect(q[:sql].length).to eq(Nightrail::Subscribers::Queries::MAX_SQL)
  end

  it "never ships Active Record's structured bind payload" do
    Nightrail.start_execution(source: :command, sample_kind: :commands)
    ActiveSupport::Notifications.instrument(
      "sql.active_record",
      sql: "SELECT * FROM widgets WHERE name = ?",
      binds: [ "structured-secret@example.test" ],
      name: "Widget Load"
    )
    Nightrail.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)

    q = nightrail_records(:query).find { |r| r[:name] == "Widget Load" }
    expect(q[:sql]).to eq("SELECT * FROM widgets WHERE name = ?")
    expect(q).not_to have_key(:binds)
    expect(q.values).not_to include("structured-secret@example.test")
  end

  it "captures sql, name, duration, connection, adapter, row_count, and in_transaction for a SELECT" do
    get "/widgets"
    q = nightrail_records(:query).find { |r| r[:sql].include?("FROM \"widgets\"") }
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
    exe = Nightrail.start_execution(source: :command, sample_kind: :commands)
    ActiveRecord::Base.transaction { Widget.create!(name: "extra") }
    Nightrail.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)

    insert = nightrail_records(:query).find { |r| r[:sql].start_with?("INSERT") }
    expect(insert[:name]).to eq("Widget Create")
    expect(insert[:affected_rows]).to eq(1)
    expect(insert[:in_transaction]).to be(true)
    expect(exe.id).to be_a(String)
  end

  it "counts a cached query on the execution's counters but never ships a query record for it" do
    Rails.cache.clear
    get "/widgets"
    get "/widgets" # second hit is served from the query cache within its own request
    expect(nightrail_records(:query)).not_to be_empty
  ensure
    Rails.cache.clear
  end

  it "skips SCHEMA and TRANSACTION named statements entirely" do
    get "/widgets"
    names = nightrail_records(:query).map { |r| r[:name] }
    expect(names).not_to include("SCHEMA", "TRANSACTION")
  end

  describe "explain capture" do
    # The throttle table is process-global (one EXPLAIN per query shape per
    # 10 minutes), so it has to be cleared or the second example in this file
    # to touch a shape gets nothing back.
    before do
      Nightrail::Subscribers::Queries.instance_variable_get(:@explained).clear
      Nightrail.config.capture_query_explain = true
      Nightrail.config.capture_sql_values = true
      Nightrail.config.explain_threshold_ms = 0.0
    end

    after do
      Nightrail.config.capture_query_explain = false
      Nightrail.config.capture_sql_values = false
      Nightrail.config.explain_threshold_ms = 100.0
    end

    # Running EXPLAIN on the same connection from inside the connection's own
    # sql.active_record notification is the risky part of this feature: it must
    # neither deadlock nor recurse.
    it "attaches the adapter's plan to a slow SELECT" do
      get "/widgets"

      q = nightrail_records(:query).find { |r| r[:sql].include?("FROM \"widgets\"") }
      expect(q[:explain]).to be_a(String)
      expect(q[:explain]).to match(/SCAN|SEARCH/) # sqlite3's EXPLAIN QUERY PLAN output
    end

    it "never records the EXPLAIN statement itself as a query" do
      get "/widgets"

      expect(nightrail_records(:query).map { |r| r[:sql] }).to all(satisfy { |sql| !sql.include?("EXPLAIN") })
    end

    it "explains a shape at most once per process within the throttle window" do
      get "/widgets"
      get "/widgets"

      widget_loads = nightrail_records(:query).select { |r| r[:sql].include?("FROM \"widgets\"") }
      expect(widget_loads.size).to be >= 2
      expect(widget_loads.count { |r| r[:explain] }).to eq(1)
    end

    it "leaves explain nil for a query faster than explain_threshold_ms" do
      Nightrail.config.explain_threshold_ms = 10_000.0
      get "/widgets"

      expect(nightrail_records(:query).map { |r| r[:explain] }.compact).to be_empty
    end

    it "still captures plans while sql itself stays normalized" do
      Nightrail.config.capture_sql_values = false
      get "/widgets"

      explained = nightrail_records(:query).reject { |r| r[:explain].nil? }
      expect(explained).not_to be_empty
      # The plan came from the raw statement; what is stored is the shape.
      expect(explained.map { |r| r[:sql] }).to all(satisfy { |sql| !sql.match?(/\bLIMIT\s+\d/) })
      expect(explained.find { |r| r[:sql].include?("gadgets") }[:sql])
        .to eq('SELECT "gadgets".* FROM "gadgets" WHERE "gadgets"."id" = ? LIMIT ?')
    end

    it "leaves explain nil for a write, which has no plan worth capturing" do
      exe = Nightrail.start_execution(source: :command, sample_kind: :commands)
      Widget.create!(name: "explained")
      Nightrail.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
      expect(exe).to be_sampled

      insert = nightrail_records(:query).find { |r| r[:sql].start_with?("INSERT") }
      expect(insert[:explain]).to be_nil
    end
  end

  it "leaves explain nil when capture_query_explain is off" do
    get "/widgets"

    expect(nightrail_records(:query).map { |r| r[:explain] }.compact).to be_empty
  end

  it "computes a caller source location for a query shape" do
    get "/many"
    sources = nightrail_records(:query).select { |r| r[:sql].include?("FROM \"gadgets\"") }.map { |r| r[:source] }
    expect(sources.compact).not_to be_empty
  end
end
