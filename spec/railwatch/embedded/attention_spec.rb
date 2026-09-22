# frozen_string_literal: true

require "spec_helper"

RSpec.describe Railwatch::Attention do
  let(:environment) { Railwatch::Environment.current }
  let(:from) { Time.utc(2026, 9, 22, 12) }
  let(:to) { from + 1.hour }
  let(:health) { { status: "ok", checked_at: to, attention: [] } }

  def attention(snapshot = health)
    described_class.new(environment, from: from, to: to, health: snapshot).to_h
  end

  def issue(**attributes)
    Railwatch::Issue.create!({ application_id: environment.application.id, environment_id: environment.id,
      group_hash: SecureRandom.hex(16), title: "Captured problem", kind: "exception", status: "open", priority: "normal",
      first_seen_at: from, last_seen_at: from + 30.minutes, affected_users: 0, occurrences: 1 }.merge(attributes))
  end

  def detection(**overrides)
    { schema_version: 1, kind: "performance", metric: "p95", unit: "milliseconds",
      window: { from: (from + 10.minutes).iso8601, to: (from + 20.minutes).iso8601 },
      measurement: { value: 900.5, limit: 500 }, baseline: { mean: 400 } }.merge(overrides)
  end

  it "ranks persisted issues by priority, affected users, recency and stable id within a bounded list" do
    low = issue(priority: "low", affected_users: 500, occurrences: 10_000, last_seen_at: to)
    normal = issue(affected_users: 999, last_seen_at: to)
    urgent = issue(priority: "urgent", last_seen_at: from)
    higher_impact = issue(priority: "high", affected_users: 9, last_seen_at: from)
    newer = issue(priority: "high", affected_users: 3, last_seen_at: to - 1.minute)
    tied_first = issue(priority: "high", affected_users: 3)
    tied_second = issue(priority: "high", affected_users: 3)
    overflow = 6.times.map { issue(priority: "low") }

    result = attention

    expect(result[:items].map { |item| item[:issue_id] }).to eq([
      urgent.id, higher_impact.id, newer.id, tied_first.id, tied_second.id, normal.id, low.id, overflow.first.id
    ])
    expect(result[:items].size).to eq(described_class::LIMIT)
    expect(attention[:items].map { |item| item[:id] }).to eq(result[:items].map { |item| item[:id] })
    expect(result).to include(open_issue_count: 13, recent_issue_count: 13, health_count: 0, from: from, to: to)
  end

  it "prioritizes critical monitoring evidence deterministically without letting it fill the issue list" do
    9.times { issue }
    snapshot = { status: "critical", checked_at: to, attention: [
      { key: "writer", severity: "critical", title: "Writer unavailable", detail: "Last captured state is closed." },
      { key: "retention", severity: "warning", title: "Retention backlog", detail: "Expired rows remain." },
      { key: "storage", severity: "critical", title: "Storage budget exceeded", detail: "Recorded storage exceeds its budget." },
      { key: "capture", severity: "warning", title: "Recorded loss", detail: "The latest batch recorded drops." }
    ] }
    original = snapshot.deep_dup

    result = attention(snapshot)

    expect(result[:items].first(3).map { |item| item[:id] }).to eq(%w[health:storage health:writer health:capture])
    expect(result[:items].count { |item| item[:type] == "issue" }).to eq(5)
    expect(result).to include(health_count: 4, health_status: "critical", checked_at: to, open_issue_count: 9)
    expect(snapshot).to eq(original)
  end

  it "keeps all-open totals separate from selected-window counts and excludes other environments and closed issues" do
    current = issue
    lower_boundary = issue(last_seen_at: from)
    upper_boundary = issue(last_seen_at: to)
    issue(last_seen_at: from - 1.second)
    issue(last_seen_at: to + 1.second)
    issue(environment_id: environment.id + 1, priority: "urgent")
    %w[resolved ignored merged].each { |status| issue(status: status, priority: "urgent") }

    result = attention

    expect(result).to include(open_issue_count: 5, recent_issue_count: 3)
    expect(result[:items].map { |item| item[:issue_id] }).to contain_exactly(current.id, lower_boundary.id, upper_boundary.id)
  end

  it "preserves typed synthetic evidence, regression state and a bounded deploy reference" do
    regression = issue(kind: "performance", regressed_at: from + 15.minutes,
      sample: { detection: detection, deploy: "a" * 150, context: "private request context", sql: "private SQL" })

    item = attention[:items].sole

    expect(item).to include(issue_id: regression.id, kind: "performance", regressed: true, deploy: "a" * 80)
    expect(item[:evidence]).to include(metric: "p95", unit: "milliseconds", value: 900.5, limit: 500, baseline_mean: 400,
      from: from + 10.minutes, to: from + 20.minutes)
    expect(item.to_json).not_to include("private request context", "private SQL")
    regression.update!(regressed_at: from - 1.second)
    expect(attention[:items].sole[:regressed]).to be(false)
  end

  it "accepts zero-valued measurements without coercing missing values to zero" do
    issue(kind: "anomaly", sample: { detection: detection(kind: "anomaly", metric: "error_rate", unit: "percent", measurement: { value: 0 }, baseline: { mean: 12 }) })

    expect(attention[:items].sole[:evidence]).to include(metric: "error_rate", unit: "percent", value: 0, limit: nil, baseline_mean: 12)
  end

  it "leaves malformed, missing and out-of-window detector snapshots unavailable while retaining the issue" do
    record = issue(kind: "performance")
    expect(attention[:items].sole[:evidence]).to be_nil
    invalid = [
      nil, "legacy", [], {}, detection(schema_version: 2), detection(kind: "anomaly"), detection(metric: "p95", unit: "percent"),
      detection(metric: "unknown"), detection(window: nil), detection(window: { from: "not-a-date", to: to.iso8601 }),
      detection(window: { from: to.iso8601, to: from.iso8601 }),
      detection(window: { from: from.iso8601, to: from.iso8601 }),
      detection(window: { from: "2" * 1_000, to: to.iso8601 }),
      detection(window: { from: (from - 1.hour).iso8601, to: (from - 1.second).iso8601 }),
      detection(window: { from: (to + 1.second).iso8601, to: (to + 1.hour).iso8601 }),
      detection(measurement: nil), detection(measurement: {}), detection(measurement: { value: "900" }),
      detection(measurement: { value: {} }), detection(measurement: { value: -1 }),
      detection(measurement: { value: 900, limit: 0 }), detection(measurement: { value: 900, limit: "500" }),
      detection(measurement: { value: 900, limit: nil }),
      detection(baseline: { mean: -1 }), detection(baseline: { mean: "400" }),
      detection(metric: "error_rate", unit: "percent", measurement: { value: 101 }),
      detection(metric: "error_rate", unit: "percent", measurement: { value: 10, limit: 101 }, baseline: { mean: 5 }),
      detection(metric: "missed", unit: "schedule", measurement: {})
    ]

    invalid.each do |snapshot|
      record.update!(sample: { detection: snapshot })
      item = attention[:items].sole
      expect(item[:issue_id]).to eq(record.id)
      expect(item[:evidence]).to be_nil, "Unexpected evidence for #{snapshot.inspect}"
    end
    record.update!(sample: [])
    expect(attention[:items].sole).to include(evidence: nil, deploy: nil)
    record.update!(kind: "exception", sample: { detection: detection })
    expect(attention[:items].sole[:evidence]).to be_nil
  end

  it "surfaces unknown monitoring health even when there are no open issues" do
    result = attention(status: "unknown", checked_at: to, attention: [])

    expect(result).to include(open_issue_count: 0, recent_issue_count: 0, health_count: 1, health_status: "unknown")
    expect(result[:items].sole).to include(id: "health:unknown", type: "health", severity: "unknown",
      title: "Monitoring evidence is incomplete")
    expect(result[:items].sole[:detail]).to include("no recorded evidence")
    expect(attention[:items]).to be_empty
  end

  it "reads only a limited issue relation and totals without running detectors or querying raw telemetry" do
    12.times { issue }
    expect(environment).not_to receive(:with_telemetry)
    expect(Railwatch::IssueDetectionSnapshot).not_to receive(:capture)
    statements = []
    capture = ->(*args) { statements << args.last[:sql] }

    ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { attention }

    reads = statements.grep(/\ASELECT/i)
    expect(reads.grep(/railwatch_issues.*LIMIT/i).size).to eq(1)
    expect(reads.grep(/COUNT\(\*\)/i).size).to be <= 2
    expect(reads.size).to be <= 3
    expect(reads).to all(include("railwatch_issues"))
    expect(statements.grep(/\A(?:INSERT|UPDATE|DELETE|CREATE|ALTER|DROP)\b/i)).to be_empty
  end
end
