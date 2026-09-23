# frozen_string_literal: true

require "spec_helper"

# Free-text search over executions matches names through the window's
# rollups rather than a LIKE over every row in the window, which read a
# week of executions to find nothing.
RSpec.describe Railwatch::Telemetry::Execution, ".named_like" do
  around do |example|
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = :http
  end

  before { Railwatch::Environment.current }

  def job(name, at:, preview: nil)
    described_class.create!(kind: "job_attempt", name: name, group_hash: Digest::MD5.hexdigest(name),
      duration: 1_000, occurred_at: at, outcome: preview ? "failed" : "processed", exception_preview: preview)
  end

  def rolled_up(name, at:, count: 1)
    Railwatch::Telemetry::Rollup.absorb!(record_type: "job_attempt", group_hash: Digest::MD5.hexdigest(name), name: name,
      bucket: Railwatch::Telemetry::Rollup.bucket_for(at), durations: [ 1_000 ] * count)
  end

  it "finds rolled-up names, names too fresh to be rolled up, and previews, inside the window only" do
    old = job("BillingSyncJob", at: 3.hours.ago)
    rolled_up("BillingSyncJob", at: 3.hours.ago)
    fresh = job("BillingExportJob", at: 1.minute.ago)
    failed = job("MailerJob", at: 2.hours.ago, preview: "Billing gateway timeout")
    job("MailerJob", at: 2.hours.ago)
    rolled_up("MailerJob", at: 2.hours.ago, count: 2)
    job("BillingArchiveJob", at: 30.hours.ago)
    rolled_up("BillingArchiveJob", at: 30.hours.ago)

    expect(described_class.named_like("job_attempt", "Billing", 1.day.ago, Time.current, previews: true))
      .to contain_exactly(old, fresh, failed)
    expect(described_class.named_like("job_attempt", "Billing", 1.day.ago, Time.current))
      .to contain_exactly(old, fresh)
  end

  it "treats LIKE wildcards in the text literally" do
    job("Percent_Job", at: 1.hour.ago)
    rolled_up("Percent_Job", at: 1.hour.ago)
    job("PercentXJob", at: 1.hour.ago)
    rolled_up("PercentXJob", at: 1.hour.ago)

    expect(described_class.named_like("job_attempt", "Percent_", 1.day.ago, Time.current).map(&:name)).to eq([ "Percent_Job" ])
  end

  it "falls back to matching the rows when the rollups say the text is common" do
    many = job("BusyJob", at: 1.hour.ago)
    rolled_up("BusyJob", at: 1.hour.ago, count: described_class::DENSE_MATCHES)

    scope = described_class.named_like("job_attempt", "Busy", 1.day.ago, Time.current)
    expect(scope.to_sql).not_to include("INDEXED BY")
    expect(scope).to contain_exactly(many)
  end
end
