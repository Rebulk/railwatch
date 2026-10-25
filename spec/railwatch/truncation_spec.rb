# frozen_string_literal: true

require "spec_helper"

# An execution whose tree outgrows execution_buffer_bytes keeps its earliest
# child records and loses the rest. The parent has to say so, and the
# subscribers must stop building what will be thrown away.
RSpec.describe "Truncated execution trees", type: :request do
  # /widgets is an N+1 on purpose: one query per widget, plus a log line.
  # Twenty widgets is a tree of twenty-odd records, so an 8 KB budget keeps
  # only the first few.
  before { 20.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) } }

  around do |example|
    previous = Railwatch.config.execution_buffer_bytes
    example.run
  ensure
    Railwatch.config.execution_buffer_bytes = previous
  end

  def child_count(request)
    request[:counters].values_at(:queries, :logs, :view_renders).compact.sum
  end

  it "puts the dropped counts on the parent record and ships the records that fit" do
    Railwatch.config.execution_buffer_bytes = 8_000

    get "/widgets"

    request = railwatch_records(:request).sole
    children = railwatch_records.reject { |r| r[:t] == "request" }
    expect(children.size).to be_between(1, 6)
    expect(request[:dropped_records]).to eq(child_count(request) - children.size)
    expect(request[:dropped_bytes]).to be > 0
  end

  it "leaves the fields off a parent whose tree fit" do
    get "/widgets"

    expect(railwatch_records(:request).sole).not_to have_key(:dropped_records)
    expect(railwatch_records(:request).sole).not_to have_key(:dropped_bytes)
  end

  it "stops building child records once the tree is full, but keeps counting them" do
    Railwatch.config.execution_buffer_bytes = 8_000
    normalized = 0
    allow(Railwatch::SqlNormalizer).to receive(:group_and_normalized).and_wrap_original do |m, *args, **kw|
      normalized += 1
      m.call(*args, **kw)
    end

    get "/widgets"

    request = railwatch_records(:request).sole
    queries = railwatch_records(:query)
    expect(request[:counters][:queries]).to be > 20
    expect(queries.size).to be < 5
    # Only the queries that were buffered were normalised, plus the one
    # whose overflow marked the buffer full. Everything after that was
    # counted at the gate without being built.
    expect(normalized).to be <= queries.size + 1
  end

  # A render past max_view_renders_per_execution is never built, full buffer
  # or not, so it is capped rather than dropped: dropped_records counts only
  # what the buffer turned away.
  it "does not count view renders past their own cap as dropped" do
    25.times { |i| Gadget.create!(name: "g#{i}") } # /many: 27 renders, cap 20
    Railwatch.config.execution_buffer_bytes = 4_000

    get "/many"

    request = railwatch_records(:request).sole
    children = railwatch_records.reject { |r| r[:t] == "request" }
    built = request[:counters].slice(:queries, :logs).values.sum +
            [ request[:counters][:view_renders], Railwatch.config.max_view_renders_per_execution ].min
    expect(request[:counters][:view_renders]).to be > Railwatch.config.max_view_renders_per_execution
    expect(request[:dropped_records]).to eq(built - children.size)
  end
end
