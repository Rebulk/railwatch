# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Lantern.span" do
  # A span needs a parent execution. A command execution is the cheapest one
  # to open without driving a request through the whole middleware stack.
  def in_execution(rate: 1.0)
    Lantern.config.sample[:commands] = rate
    Lantern.start_execution(source: :command, sample_kind: :commands)
    yield
  ensure
    Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo",
                             command: "rake demo", exit_code: 0)
  end

  it "returns the block's value" do
    expect(in_execution { Lantern.span("pdf.render") { 6 * 7 } }).to eq(42)
  end

  it "records one span with status ok and a duration in microseconds" do
    in_execution { Lantern.span("pdf.render") { sleep 0.002 } }

    span = lantern_records(:span).sole
    expect(span[:name]).to eq("pdf.render")
    expect(span[:status]).to eq("ok")
    expect(span[:duration]).to be_a(Integer).and be >= 2_000
  end

  it "records the span as failed and re-raises the block's exception" do
    expect { in_execution { Lantern.span("pdf.render") { raise ArgumentError, "nope" } } }
      .to raise_error(ArgumentError, "nope")

    expect(lantern_records(:span).sole).to include(name: "pdf.render", status: "failed")
  end

  it "counts every span on the execution's spans counter" do
    in_execution { 3.times { |i| Lantern.span("step-#{i}") { i } } }

    expect(lantern_records(:command).sole[:counters][:spans]).to eq(3)
  end

  it "still yields, records nothing, and counts nothing when Lantern is disabled" do
    Lantern.config.enabled = false

    expect(in_execution { Lantern.span("pdf.render") { 42 } }).to eq(42)
    expect(lantern_records(:span)).to be_empty
    expect(lantern_records(:command).sole[:counters][:spans]).to eq(0)
  ensure
    Lantern.config.enabled = true
  end

  it "still yields and records nothing outside any execution" do
    expect(Lantern.span("pdf.render") { 42 }).to eq(42)

    expect(lantern_records(:span)).to be_empty
  end

  it "still yields and records nothing when the execution is sampled out" do
    expect(in_execution(rate: 0.0) { Lantern.span("pdf.render") { 42 } }).to eq(42)

    expect(lantern_records(:span)).to be_empty
  end

  it "still yields and records nothing inside a Lantern.ignore block" do
    result = in_execution { Lantern.ignore { Lantern.span("pdf.render") { 42 } } }

    expect(result).to eq(42)
    expect(lantern_records(:span)).to be_empty
  end
end
