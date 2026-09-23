# frozen_string_literal: true

require "spec_helper"

# The Tenants page counted untagged requests with app_tenant IS NULL and
# drew sparklines grouped over every request, which read the whole window:
# 11 s over a week on an app with no tenants. Both now go through the
# tenant-led indexes. The numbers must not move.
RSpec.describe Railwatch::Telemetry::Tenant, "index page aggregates" do
  around do |example|
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = :http
  end

  before { Railwatch::Environment.current }

  let(:from) { 1.day.ago }
  let(:to) { Time.current }

  def request(tenant, at: 1.hour.ago)
    Railwatch::Telemetry::Execution.create!(kind: "request", name: "GET /", group_hash: "g", duration: 1_000,
      status: 200, occurred_at: at, app_tenant: tenant)
  end

  it "reports the untagged share of the whole window, even when q narrows the tenants listed" do
    request("acme")
    request("acme")
    request("globex")
    request(nil)

    all = described_class.overview(described_class.index(from, to), from, to)
    searched = described_class.overview(described_class.index(from, to, q: "acme"), from, to)

    expect(all).to include(tenants: 2, untagged_share: 25.0)
    expect(searched).to include(tenants: 1, top_tenant: "acme", untagged_share: 25.0)
  end

  it "draws each listed tenant's sparkline from its own requests" do
    request("acme", at: 20.hours.ago)
    request("acme", at: 1.hour.ago)
    request(nil, at: 1.hour.ago)

    row = described_class.index(from, to).sole
    expect(row[:tenant]).to eq("acme")
    expect(row[:sparkline].sum).to eq(2)
    expect(row[:sparkline].count(&:positive?)).to eq(2)
  end
end
