# frozen_string_literal: true

require "spec_helper"

RSpec.describe "development timing headers", type: :request do
  before do
    3.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) }
    Railwatch.config.timing_headers = true
  end

  after { Railwatch.config.timing_headers = nil }

  def server_timing
    response.headers["Server-Timing"].split(", ").to_h do |metric|
      name, *params = metric.split(";")
      [ name, params.to_h { |param| param.split("=", 2) } ]
    end
  end

  it "names the execution the request recorded, for get_execution" do
    get "/widgets"

    expect(response.headers["X-Railwatch-Execution-Id"]).to eq(railwatch_records(:request).sole[:execution_id])
  end

  it "says what the request spent on the database, and how many queries that was" do
    get "/widgets"

    request = railwatch_records(:request).sole
    timing = server_timing
    expect(timing["db"]).to eq("dur" => format("%.1f", request[:db_runtime]), "desc" => "\"#{request[:counters][:queries]} queries\"")
    expect(timing["view"]["dur"].to_f).to be_within(0.05).of(request[:view_runtime])
    # Measured as the response leaves the app, just before the record is finished.
    expect(timing["total"]["dur"].to_f).to be_between(timing["db"]["dur"].to_f, request[:duration] / 1000.0)
    expect(timing["other"]["dur"].to_f).to be >= 0
  end

  it "is off unless asked for outside development" do
    Railwatch.config.timing_headers = nil

    get "/widgets"

    expect(Rails.env).to eq("test")
    expect(response.headers).not_to include("X-Railwatch-Execution-Id", "Server-Timing")
  end
end
