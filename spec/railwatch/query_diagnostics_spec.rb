# frozen_string_literal: true

require "spec_helper"
require "railwatch/query_diagnostics"

RSpec.describe Railwatch::QueryDiagnostics do
  def analyze(sql = "SELECT * FROM events", adapter: "PostgreSQL", **options)
    described_class.call(sql: sql, adapter: adapter, connection: "primary", **options)
  end

  def indexes(result) = result[:recommendations].select { |r| r[:basis] == "sql" }
  def observations(result) = result[:recommendations].select { |r| r[:basis] == "plan" }

  it "derives a qualified composite candidate from equality predicates and ordering" do
    result = analyze('SELECT "events".* FROM "public"."events" AS e WHERE e."account_id" = $1 AND e."status" = $2 ORDER BY e."created_at" DESC', source: "app/models/event.rb:12")
    candidate = indexes(result).sole
    expect(result).to include(status: "analyzed", adapter: "PostgreSQL", connection: "primary", source: "app/models/event.rb:12")
    expect(candidate).to include(table: '"public"."events"', columns: [ '"account_id"', '"status"', '"created_at"' ], basis: "sql")
    expect(candidate[:evidence].map { |e| e[:text] }).to include('e."account_id" = ?', 'ORDER BY e."created_at" DESC')
    expect(candidate[:explanation]).to include("may help", "not a verified index definition")
    expect(result[:limitations].join).to include("may already exist", "No stored EXPLAIN")
    expect(result.to_s).not_to match(/CREATE INDEX|ALTER TABLE/)
  end

  it "handles aliases and explicit joins without assigning a column to the wrong table" do
    result = analyze("SELECT c.* FROM comments c JOIN posts p ON p.id = c.post_id WHERE c.state = :state ORDER BY c.created_at DESC", adapter: "SQLite3")
    candidate = indexes(result).sole
    expect(candidate).to include(table: "comments", columns: %w[post_id state created_at])
    expect(candidate[:evidence].map { |e| e[:text] }).to include("p.id = c.post_id")
    expect(result[:limitations].join).to include("Join order")
  end

  it "supports backticks and question-mark binds for MySQL and Trilogy" do
    %w[Mysql2 Trilogy].each do |adapter|
      result = analyze('SELECT `audit``events`.* FROM `audit``events` WHERE `tenant_id` = ? AND `created_at` >= ? ORDER BY `created_at` DESC', adapter: adapter)
      expect(indexes(result).sole).to include(table: '`audit``events`', columns: [ '`tenant_id`', '`created_at`' ])
    end
  end

  it "supports escaped and Unicode quoted identifiers without generating SQL" do
    result = analyze('SELECT * FROM "événements" WHERE "odd""key" = $1 ORDER BY "時刻" DESC')
    expect(indexes(result).sole).to include(table: '"événements"', columns: [ '"odd""key"', '"時刻"' ])
    expect(analyze('SELECT * FROM "public.events" WHERE public.events.tenant_id = ?')[:status]).to eq("unsupported")
  end

  it "supports bracket identifiers and bound parameters for SQLite" do
    result = analyze("SELECT * FROM [audit events] WHERE [tenant id] = @tenant AND ([state] = :state) ORDER BY [created at] DESC", adapter: "SQLite")
    expect(indexes(result).sole[:columns]).to eq([ "[tenant id]", "[state]", "[created at]" ])
  end

  it "supports NULL equality filters without treating equality to NULL as a predicate" do
    result = analyze("SELECT * FROM events WHERE tenant_id = ? AND deleted_at IS NULL ORDER BY created_at DESC")
    expect(indexes(result).sole[:columns]).to eq(%w[tenant_id deleted_at created_at])
    expect(indexes(result).sole[:evidence].map { |e| e[:text] }).to include("deleted_at IS NULL")
  end

  it "deduplicates equivalent quoted keys and respects PostgreSQL case-sensitive identifiers" do
    result = analyze('SELECT * FROM events WHERE tenant_id = ? AND "tenant_id" = ? ORDER BY created_at, "created_at"')
    expect(indexes(result).sole[:columns]).to eq(%w[tenant_id created_at])
    result = analyze('SELECT * FROM events WHERE tenant_id = ? AND "Tenant_id" = ?')
    expect(indexes(result).sole[:columns]).to eq([ "tenant_id", '"Tenant_id"' ])
  end

  it "does not mistake literal contents and SQL comments for query structure" do
    result = analyze("SELECT * FROM events WHERE label = 'WHERE password = 1 OR account_id = 2' /* ORDER BY secret */")
    expect(indexes(result).sole[:columns]).to eq([ "label" ])
    expect(indexes(result).sole[:evidence].sole[:text]).to eq("label = ?")
    expect(analyze("SELECT * FROM events WHERE tenant_id = ? /*! OR public = 1 */", adapter: "Mysql2")[:status]).to eq("unsupported")
  end

  it "keeps range columns before compatible sort keys and does not promise a different ordering" do
    result = analyze("SELECT * FROM events WHERE tenant_id = ? AND created_at >= ? ORDER BY score DESC")
    expect(indexes(result).sole[:columns]).to eq(%w[tenant_id created_at])
    expect(indexes(result).sole[:explanation]).not_to include("the ordering")
  end

  it "does not treat a normalized IN list as a single equality for ordering" do
    result = analyze("SELECT * FROM events WHERE tenant_id IN (1, 2) ORDER BY created_at DESC")
    expect(indexes(result).sole[:columns]).to eq([ "tenant_id" ])
    expect(indexes(result).sole[:explanation]).to include("membership")
    expect(indexes(result).sole[:explanation]).not_to include("the ordering")
  end

  it "does not invent a column order for multiple independent ranges" do
    result = analyze("SELECT * FROM events WHERE created_at >= ? AND score > ?")
    expect(indexes(result)).to be_empty
    expect(result[:limitations].join).to include("Multiple range predicates")
  end

  it "keeps routine primary-key lookups and unfiltered reads quiet" do
    [ "SELECT * FROM events WHERE id = ?", "SELECT * FROM events", "SELECT * FROM events LIMIT ?" ].each do |sql|
      expect(analyze(sql)[:status]).to eq("analyzed")
      expect(indexes(analyze(sql))).to be_empty
    end
  end

  it "fails closed on complex, ambiguous or unsafe shapes" do
    [
      "SELECT * FROM events WHERE tenant_id = ? OR public = ?",
      "SELECT * FROM events WHERE NOT tenant_id = ?",
      "SELECT * FROM events WHERE lower(email) = ?",
      "SELECT * FROM events WHERE tenant_id + ? = ?",
      "SELECT * FROM events WHERE tenant_id = (SELECT id FROM tenants)",
      "WITH recent AS (SELECT * FROM events) SELECT * FROM recent WHERE id = ?",
      "SELECT * FROM events WHERE tenant_id = ?; DROP TABLE events",
      "SELECT * FROM events e JOIN tenants t ON e.tenant_id = t.id WHERE state = ?",
      "SELECT * FROM events e JOIN events previous ON e.id = previous.id WHERE e.state = ?",
      "SELECT * FROM events WHERE tenant_id = NULL",
      "SELECT * FROM events WHERE tenant_id = ? ORDER BY random()",
      "SELECT * FROM events WHERE tenant_id = ? UNION SELECT * FROM events",
      "UPDATE events SET label = ? WHERE tenant_id = ?",
      'SELECT * FROM "unterminated WHERE tenant_id = ?',
      "SELECT * FROM events WHERE tenant_id = ? [SQL TRUNCATED]"
    ].each do |sql|
      result = analyze(sql)
      expect(result[:status]).to eq("unsupported"), sql
      expect(indexes(result)).to be_empty, sql
    end
  end

  it "reports absent and unsupported adapter evidence explicitly" do
    expect(analyze(nil)[:status]).to eq("unavailable")
    expect(analyze("SELECT * FROM events WHERE tenant_id = ?", adapter: "SQLServer")[:status]).to eq("unsupported")
    expect(analyze("SELECT * FROM events WHERE tenant_id = ?", adapter: nil)[:recommendations]).to be_empty
  end

  it "bounds SQL work, token count, nesting and output evidence" do
    expect(analyze("SELECT * FROM events WHERE tenant_id = ? " + " " * 16_384)[:status]).to eq("limited")
    expect(analyze("SELECT " + ("a," * 2_001) + "a FROM events WHERE tenant_id = ?")[:status]).to eq("unsupported")
    expect(analyze("SELECT * FROM events WHERE " + "(" * 30 + "tenant_id = ?" + ")" * 30)[:status]).to eq("unsupported")
    result = analyze('SELECT * FROM events WHERE "' + "a" * 1_200 + '" = ?')
    expect(indexes(result).sole[:evidence].sole).to include(truncated: true)
    expect(indexes(result).sole[:evidence].sole[:text].bytesize).to be <= described_class::MAX_EVIDENCE_BYTES
  end

  it "records PostgreSQL scan and sort facts with original line numbers" do
    plan = "Sort  (cost=4.2..5.0 rows=12)\n  Sort Key: created_at\n  ->  Seq Scan on events (cost=0..4 rows=12)"
    result = analyze(plan: { plan: plan, adapter: "PostgreSQL" })
    expect(observations(result).map { |r| r[:kind] }).to eq(%w[sort scan])
    expect(observations(result).last[:evidence].sole).to include(text: "  ->  Seq Scan on events (cost=0..4 rows=12)", line: 3)
    expect(observations(result).last[:explanation]).to include("even when an index exists")
    expect(result[:limitations].join).to include("does not prove an index is missing")
  end

  it "uses the plan sample's own adapter" do
    result = analyze(adapter: "SQLite", plan: { plan: "Seq Scan on events", adapter: "PostgreSQL" })
    expect(observations(result).sole[:kind]).to eq("scan")
    expect(observations(analyze(plan: { plan: "Seq Scan on events", adapter: nil }))).to be_empty
  end

  it "recognizes real SQLite temp B-tree wording and distinguishes index scans" do
    result = analyze(plan: { plan: "SCAN events\nUSE TEMP B-TREE FOR ORDER BY", adapter: "SQLite3" })
    expect(observations(result).map { |r| r[:kind] }).to eq(%w[scan sort])
    result = analyze(plan: { plan: "SCAN events USING INDEX idx_events\nSCAN events USING COVERING INDEX idx_cover\nSCAN CONSTANT ROW", adapter: "SQLite" })
    expect(observations(result)).to be_empty
  end

  it "reads MySQL tabular plans and does not report filesort when absent" do
    plan = "+----+-------+------+-----------------------------+\n| id | table | type | Extra |\n| 1 | events | ALL | Using where; Using filesort |"
    result = analyze(plan: { plan: plan, adapter: "Mysql2" })
    expect(observations(result).map { |r| r[:kind] }).to eq(%w[sort scan])
    expect(observations(analyze(plan: { plan: "| id | table | type | Extra |\n| 1 | events | ref | Using index |", adapter: "Trilogy" }))).to be_empty
    expect(observations(analyze(plan: { plan: "| id | table | type | Extra |\n| 1 | events | ALL | |", adapter: "Mysql2" })).sole[:kind]).to eq("scan")
  end

  it "does not interpret predicates containing plan words as plan operations" do
    result = analyze(plan: { plan: "Index Scan using idx on events\n  Filter: (label = 'Seq Scan on events')\n  Sort Key: created_at", adapter: "PostgreSQL" })
    expect(observations(result)).to be_empty
    result = analyze(plan: { plan: "Filter: (label = 'type: ALL Extra: Using filesort')", adapter: "Mysql2" })
    expect(observations(result)).to be_empty
  end

  it "bounds stored plans and the number of findings" do
    result = analyze(plan: { plan: "Seq Scan on events\n" * 3_000, adapter: "PostgreSQL" })
    expect(observations(result).size).to be <= 6
    expect(result[:limitations].join).to include("first 32768 bytes and 200 lines")
    expect(observations(result).all? { |r| r[:evidence].sole[:line] <= 200 }).to be(true)
    result = analyze(plan: { plan: "type: ALL\n" * 5 + "type: ALL Extra: Using filesort", adapter: "Mysql2" })
    expect(observations(result).size).to eq(6)
  end

  it "includes the captured N+1 example with explicit association verification" do
    result = analyze("SELECT * FROM comments WHERE post_id = ?", n_plus_one: { count: 7, sql: "SELECT * FROM comments WHERE post_id = ?", source: "app/views/posts/index:4",
      suggestion: { code: "Post.includes(:comments)", explanation: "Preload comments on the post collection." } })
    repeated = result[:recommendations].find { |r| r[:kind] == "n_plus_one" }
    expect(repeated).to include(basis: "capture", code: "Post.includes(:comments)")
    expect(repeated[:explanation]).to include("7 times in one execution")
    expect(repeated[:action]).to include("Verify the inferred association names")
  end
end
