# frozen_string_literal: true

require "spec_helper"

RSpec.describe "view_render record", type: :request do
  it "captures kind template and kind layout for the top-level render, and kind partial/collection for nested renders" do
    3.times { |i| Gadget.create!(name: "g#{i}") }
    get "/many" # renders a single partial, a 3-item collection, and 3 individual partials in a loop

    renders = nightrail_records(:view_render)

    template = renders.find { |r| r[:kind] == "template" }
    expect(template[:identifier]).to eq("app/views/widgets/many.html.erb")
    expect(template[:layout]).to eq("layouts/application")
    expect(template[:duration]).to be_a(Integer).and be >= 0

    layout = renders.find { |r| r[:kind] == "layout" }
    expect(layout[:identifier]).to eq("app/views/layouts/application.html.erb")

    collection = renders.find { |r| r[:kind] == "collection" }
    expect(collection[:identifier]).to eq("app/views/gadgets/_gadget.html.erb")
    expect(collection[:count]).to eq(3)

    partials = renders.select { |r| r[:kind] == "partial" }
    # the standalone render (@gadgets.first) plus one per gadget in the explicit loop
    expect(partials.size).to eq(4)
    expect(partials).to all(include(identifier: "app/views/gadgets/_gadget.html.erb"))
  end

  it "stops shipping records once max_view_renders_per_execution is reached, even though more renders occurred" do
    25.times { |i| Gadget.create!(name: "g#{i}") } # 1 + 1 + 25 = 27 render events, well past the cap of 20
    get "/many"

    expect(nightrail_records(:view_render).size).to eq(Nightrail.config.max_view_renders_per_execution)
  end
end
