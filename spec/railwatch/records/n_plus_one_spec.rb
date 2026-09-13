# frozen_string_literal: true

require "spec_helper"

RSpec.describe "n_plus_one record", type: :request do
  it "fires exactly once, at the configured threshold, with the group's sql shape and count" do
    Railwatch.config.n_plus_one_threshold = 3
    4.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) }

    get "/widgets" # index does widget.gadget&.name for each widget -- N+1 by construction

    n1s = railwatch_records(:n_plus_one)
    expect(n1s.size).to eq(1)
    expect(n1s.first[:sql]).to include("gadgets")
    expect(n1s.first[:count]).to eq(3)
  ensure
    Railwatch.config.n_plus_one_threshold = 5
  end

  it "does not fire below the threshold" do
    Railwatch.config.n_plus_one_threshold = 10
    3.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) }

    get "/widgets"

    expect(railwatch_records(:n_plus_one)).to be_empty
  ensure
    Railwatch.config.n_plus_one_threshold = 5
  end
end
