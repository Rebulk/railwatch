# frozen_string_literal: true

require "spec_helper"

# The engine's in-app dashboard: telemetry written straight into the
# railwatch_telemetry database by Transport::Local, read back by the same
# controllers the hosted platform runs, rendered through the vendored
# Inertia bundle. Needs the dummy app's railwatch and railwatch_telemetry
# databases (spec/dummy/config/database.yml) with both schemas loaded.
RSpec.describe "embedded dashboard", type: :request do
  around do |example|
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = :http
  end

  def inertia_headers = { "X-Inertia" => "true", "X-Inertia-Version" => Railwatch::AssetsHelper.digest }

  def local_write!(records)
    result = Railwatch::Transport::Local.new(Railwatch.config).deliver(records)
    expect(result.ok).to be(true), result.error.to_s
    result
  end

  it "writes a request record into the telemetry database and shows it on the requests page" do
    get "/widgets"
    records = railwatch_records
    expect(records.map { |r| r[:t] }).to include("request")

    local_write!(records)

    stored = Railwatch::Environment.current.with_telemetry { Railwatch::Telemetry::Execution.where(kind: "request").last }
    expect(stored).to be_present
    expect(stored.name).to eq("GET /widgets(.:format)")

    get "/railwatch/apps/1/envs/1/requests/#{stored.execution_id}", headers: inertia_headers
    expect(response).to have_http_status(:ok)
    page = response.parsed_body
    expect(page["component"]).to eq("executions/show")
    expect(page["props"]["embedded"]).to be(true)
    expect(page["props"]["environment"]).to include("id" => 1, "name" => "test")
    expect(page["props"]["execution"]).to include("name" => "GET /widgets(.:format)", "kind" => "request")
  end

  it "groups a raised exception into an issue with the app's prefix and lists it" do
    get "/boom"
    result = local_write!(railwatch_records)
    expect(result.rejected).to eq(0)
    perform_enqueued_jobs(only: Railwatch::GroupExceptionsJob)

    issue = Railwatch::Issue.sole
    expect(issue.key).to eq("DUMM-1")
    expect(issue.title).to eq("ArgumentError: kaboom")
    expect(issue.environment_id).to eq(1)

    get "/railwatch/issues", headers: inertia_headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["props"]["issues"].map { |i| i["key"] }).to eq([ "DUMM-1" ])

    get "/railwatch/issues/#{issue.id}", headers: inertia_headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["props"]["issue"]["key"]).to eq("DUMM-1")
  end

  it "serves the vendored bundle's HTML shell, assets and favicon without an asset pipeline" do
    get "/railwatch"
    expect(response).to redirect_to("/railwatch/apps/1/envs/1")

    get "/railwatch/apps/1/envs/1"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('<meta name="railwatch-mount" content="/railwatch">')
    expect(response.body).to include('data-page=')
    script = response.body[%r{/railwatch/assets/assets/[^"']+\.js}]
    expect(script).to be_present

    get script
    expect(response).to have_http_status(:ok)
    expect(response.headers["cache-control"]).to include("immutable")

    get "/railwatch/icon.svg"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/svg+xml")
  end

  it "names the operator from the host's dashboard_user resolver" do
    Railwatch.config.dashboard_user = ->(_request) { { id: 7, name: "Ada", email: "ada@example.com" } }

    get "/railwatch/apps/1/envs/1", headers: inertia_headers
    expect(response.parsed_body["props"]["auth"]["user"]).to include("name" => "Ada", "email" => "ada@example.com")
  ensure
    Railwatch.config.dashboard_user = nil
  end

  it "refuses a stale bundle version with the Inertia 409 so the browser reloads" do
    get "/railwatch/apps/1/envs/1", headers: inertia_headers.merge("X-Inertia-Version" => "stale")
    expect(response).to have_http_status(:conflict)
    expect(response.headers["X-Inertia-Location"]).to end_with("/railwatch/apps/1/envs/1")
  end
end
