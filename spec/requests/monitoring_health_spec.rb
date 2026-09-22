# frozen_string_literal: true

require "spec_helper"

RSpec.describe "embedded monitoring health", type: :request do
  around do |example|
    previous = Railwatch.config.transport
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = previous
  end

  let(:path) { "/railwatch/apps/1/envs/1/monitoring_health" }
  let(:headers) { { "X-Inertia" => "true", "X-Inertia-Version" => Railwatch::AssetsHelper.digest } }

  it "serves the shared health snapshot through the embedded authenticated dashboard" do
    Railwatch::Telemetry::IngestBatch.create!(received_at: Time.current, accepted: 5, dropped_by_client: 2)

    get path, headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["component"]).to eq("monitoring_health/show")
    snapshot = response.parsed_body.dig("props", "monitoring_health")
    expect(snapshot).to include("host" => "embedded")
    expect(snapshot["capture"]).to include("accepted" => 5, "dropped_by_client" => 2)
    expect(snapshot["attention"].map { |item| item["key"] }).to include("capture")
  end

  it "requires the same authentication as the other embedded pages before reading diagnostics" do
    Railwatch.config.http_basic_auth_enabled = true
    expect(Railwatch::MonitoringHealth).not_to receive(:new)

    get path, headers: headers

    expect(response).to have_http_status(:unauthorized)
  ensure
    Railwatch.config.http_basic_auth_enabled = false
  end

  it "shows the schema repair state before reading monitoring health when migrations are pending" do
    connection = Railwatch::TelemetryRecord.connection
    version = connection.select_value("SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1")
    connection.execute("DELETE FROM schema_migrations WHERE version = #{connection.quote(version)}")
    Railwatch::RuntimeSchema.invalidate!
    expect(Railwatch::MonitoringHealth).not_to receive(:new)

    get path, headers: headers

    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).to include("Pending migrations", "db:migrate:railwatch_telemetry")
    expect(response.headers["Cache-Control"]).to include("no-store")
  ensure
    Railwatch::RuntimeSchema.invalidate!
  end
end
