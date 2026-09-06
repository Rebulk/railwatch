# frozen_string_literal: true

require "spec_helper"

RSpec.describe "n_plus_one record", type: :request do
  it "fires exactly once, at the configured threshold, with the group's sql shape and count" do
    Nightrail.config.n_plus_one_threshold = 3
    4.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) }

    get "/widgets" # index does widget.gadget&.name for each widget -- N+1 by construction

    n1s = nightrail_records(:n_plus_one)
    expect(n1s.size).to eq(1)
    expect(n1s.first[:sql]).to include("gadgets")
    expect(n1s.first[:count]).to eq(3)
  ensure
    Nightrail.config.n_plus_one_threshold = 5
  end

  it "does not fire below the threshold" do
    Nightrail.config.n_plus_one_threshold = 10
    3.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) }

    get "/widgets"

    expect(nightrail_records(:n_plus_one)).to be_empty
  ensure
    Nightrail.config.n_plus_one_threshold = 5
  end
end
