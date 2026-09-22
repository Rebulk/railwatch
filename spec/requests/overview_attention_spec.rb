# frozen_string_literal: true

require "spec_helper"

RSpec.describe "embedded overview attention", type: :request do
  around do |example|
    previous = Railwatch.config.transport
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = previous
  end

  it "counts all open issues, bounds the triage list and scopes its observations to the selected window" do
    10.times do |index|
      Railwatch::Environment.current.issues.create!(application_id: 1, group_hash: "attention-#{index}",
        kind: "exception", title: "Issue #{index}", last_seen_at: 10.minutes.ago, first_seen_at: 2.days.ago)
    end
    Railwatch::Environment.current.issues.create!(application_id: 1, group_hash: "old", kind: "exception", title: "Old issue",
      first_seen_at: 3.days.ago, last_seen_at: 2.days.ago)

    get "/railwatch/apps/1/envs/1", params: { window: "1h" },
      headers: { "X-Inertia" => "true", "X-Inertia-Version" => Railwatch::AssetsHelper.digest }

    expect(response).to have_http_status(:ok)
    props = response.parsed_body["props"]
    expect(props["issues"].length).to eq(8)
    expect(props["attention"]).to include("open_issue_count" => 11, "recent_issue_count" => 10)
    expect(props["attention"]["items"].length).to be <= 8
    expect(props["attention"]["items"].map { |item| item["title"] }).not_to include("Old issue")
  end
end
