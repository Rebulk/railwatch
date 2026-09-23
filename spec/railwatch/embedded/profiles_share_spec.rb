# frozen_string_literal: true

require "spec_helper"

# The Profiles page's "profiled" share divides by the window's executions,
# taken from hourly rollups. A rollup holds its whole hour, so a window that
# starts or ends mid-hour counts its partial hours from the rows instead.
RSpec.describe Railwatch::ProfilesController, "executions in the window" do
  let(:controller) { described_class.new }
  let(:hour) { Time.utc(2026, 9, 20, 10) }

  around do |example|
    Railwatch.config.transport = :local
    example.run
  ensure
    Railwatch.config.transport = :http
  end

  before { Railwatch::Environment.current }

  def execution(at)
    Railwatch::Telemetry::Execution.create!(kind: "request", name: "GET /", group_hash: "g", duration: 1_000, status: 200, occurred_at: at)
  end

  it "counts executions inside a window that starts and ends mid-hour, and none outside it" do
    [ 10, 40, 90, 140, 170 ].each { |minutes| execution(hour + minutes.minutes) }
    [ hour, hour + 1.hour, hour + 2.hours ].each do |bucket|
      Railwatch::Telemetry::Rollup.create!(record_type: "request", group_hash: "g", name: "GET /", bucket: bucket,
        count: Railwatch::Telemetry::Execution.where(occurred_at: bucket...(bucket + 1.hour)).count)
    end

    expect(controller.send(:executions_in, hour + 20.minutes, hour + 150.minutes)).to eq(3)
    expect(controller.send(:executions_in, hour, hour + 3.hours)).to eq(5)
    expect(controller.send(:executions_in, hour + 20.minutes, hour + 50.minutes)).to eq(1)
  end
end
