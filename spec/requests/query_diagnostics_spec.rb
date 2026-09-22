# frozen_string_literal: true

require "spec_helper"

RSpec.describe "embedded query diagnostics", type: :request do
  before { allow(Railwatch::AssetsHelper).to receive(:digest).and_return("query-diagnostics-spec") }

  around do |example|
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = :http
  end

  def inertia_headers = { "X-Inertia" => "true", "X-Inertia-Version" => Railwatch::AssetsHelper.digest }
  def telemetry(&) = Railwatch::Environment.current.with_telemetry(&)

  it "shows qualified shared advice, a stored plan and the captured N+1 suggestion" do
    # The captured table does not exist in the dashboard's database. Rendering
    # diagnostics must only read the telemetry, never execute this statement.
    sql = 'SELECT "comments".* FROM "comments" WHERE "comments"."post_id" = ? ORDER BY "comments"."created_at" DESC'
    group = Railwatch::SqlNormalizer.group(sql, adapter: "postgresql", connection_name: "replica")
    telemetry do
      Railwatch::Telemetry::Query.create!(group_hash: group, sql: sql, adapter: "postgresql", connection: "replica",
        source: "app/views/posts/index:7", occurred_at: Time.current, duration: 120_000, explain: "Seq Scan on comments")
      Railwatch::Telemetry::NPlusOne.create!(group_hash: group, sql: sql, source: "app/views/posts/index:7", count: 6, occurred_at: Time.current)
    end

    get "/railwatch/apps/1/envs/1/queries/#{group}", headers: inertia_headers
    expect(response).to have_http_status(:ok)
    props = response.parsed_body["props"]
    expect(props["diagnostics"]).to include("status" => "analyzed", "adapter" => "postgresql", "connection" => "replica")
    expect(props["diagnostics"]["recommendations"].map { |r| r["basis"] }).to contain_exactly("sql", "plan", "capture")
    expect(props["diagnostics"]["recommendations"].find { |r| r["basis"] == "capture" }["code"]).to eq("Post.includes(:comments)")
    expect(props["explain"]).to include("adapter" => "postgresql", "connection" => "replica", "plan" => "Seq Scan on comments")
  end

  it "keeps evidence inside the selected group and time window" do
    telemetry do
      Railwatch::Telemetry::Query.create!(group_hash: "current", sql: "SELECT * FROM widgets WHERE id = ?", adapter: "sqlite", occurred_at: Time.current, duration: 10)
      Railwatch::Telemetry::Query.create!(group_hash: "other", sql: "SELECT * FROM comments", adapter: "sqlite", occurred_at: Time.current, duration: 10, explain: "SCAN comments")
      Railwatch::Telemetry::NPlusOne.create!(group_hash: "current", sql: "SELECT * FROM comments WHERE post_id = ?", count: 7, occurred_at: 3.days.ago)
    end
    get "/railwatch/apps/1/envs/1/queries/current", headers: inertia_headers
    props = response.parsed_body["props"]
    expect(props["explain"]).to be_nil
    expect(props["diagnostics"]["recommendations"]).to be_empty
  end

  it "handles missing samples and caps the rendered plan" do
    get "/railwatch/apps/1/envs/1/queries/missing", headers: inertia_headers
    expect(response.parsed_body["props"]["diagnostics"]).to include("status" => "unavailable", "recommendations" => [])

    telemetry do
      Railwatch::Telemetry::Query.create!(group_hash: "large", sql: "SELECT * FROM widgets", adapter: "sqlite", occurred_at: Time.current,
        duration: 10, explain: "SCAN widgets\n" * 500)
    end
    get "/railwatch/apps/1/envs/1/queries/large", headers: inertia_headers
    props = response.parsed_body["props"]
    expect(props["explain"]["truncated"]).to be(true)
    expect(props["explain"]["plan"].lines.size).to eq(200)
    expect(props["diagnostics"]["limitations"].join).to include("first 32768 bytes and 200 lines")
  end
end
