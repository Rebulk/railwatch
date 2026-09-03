# frozen_string_literal: true

require "spec_helper"

RSpec.describe "span record" do
  def record_span(name, **attributes)
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern.span(name, **attributes) { :done }
    Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo",
                             command: "rake demo", exit_code: 0)
    lantern_records(:span).sole
  end

  it "ships as a v1 span with the name, its group hash, and no attributes when none were given" do
    span = record_span("pdf.render")

    expect(span[:v]).to eq(1)
    expect(span[:t]).to eq("span")
    expect(span[:_group]).to eq(Lantern::Record.group_hash("pdf.render"))
    expect(span[:name]).to eq("pdf.render")
    expect(span[:status]).to eq("ok")
    expect(span[:attributes]).to be_nil
  end

  it "truncates the name to 255 characters" do
    span = record_span("x" * 300)

    expect(span[:name].length).to eq(255)
  end

  it "belongs to the execution it ran inside" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern.span("pdf.render") { :done }
    Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo",
                             command: "rake demo", exit_code: 0)

    span = lantern_records(:span).sole
    command = lantern_records(:command).sole
    expect(span[:execution_id]).to eq(command[:execution_id])
    expect(span[:execution_source]).to eq("command")
  end

  it "stringifies attribute keys and values, keeping them under 200 characters" do
    span = record_span("pdf.render", pages: 12, template: "invoice")

    expect(span[:attributes]).to eq("pages" => "12", "template" => "invoice")
  end

  it "truncates an attribute value to 200 characters" do
    span = record_span("pdf.render", note: "a" * 500)

    expect(span[:attributes]["note"].length).to eq(200)
  end

  it "redacts attributes through the same parameter filter as request params" do
    span = record_span("pdf.render", password: "hunter2", user: "cole")

    expect(span[:attributes]).to eq("password" => "[FILTERED]", "user" => "cole")
  end

  it "keeps at most 25 attributes" do
    span = record_span("pdf.render", **30.times.to_h { |i| [ :"k#{i}", i ] })

    expect(span[:attributes].size).to eq(25)
    expect(span[:attributes].keys.last).to eq("k24")
  end
end
