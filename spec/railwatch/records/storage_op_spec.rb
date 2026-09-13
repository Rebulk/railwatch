# frozen_string_literal: true

require "spec_helper"

RSpec.describe "storage_op record", type: :request do
  it "captures service, op, key, and duration for attach/download/url/purge on an Active Storage attachment" do
    Widget.create!(name: "storage widget") # WidgetsController#storage operates on Widget.first
    get "/storage" # attaches a photo, then downloads/urls/purges it

    ops = railwatch_records(:storage_op)
    upload = ops.find { |r| r[:op] == "upload" }
    expect(upload[:service]).to eq("Disk")
    expect(upload[:key]).to be_a(String).and be_present
    expect(upload[:duration]).to be_a(Integer).and be >= 0

    download = ops.find { |r| r[:op] == "download" }
    expect(download[:key]).to eq(upload[:key]) # same blob throughout the request

    url = ops.find { |r| r[:op] == "url" }
    expect(url[:key]).to eq(upload[:key])

    delete = ops.find { |r| r[:op] == "delete" } # purge issues a delete
    expect(delete[:key]).to eq(upload[:key])
  end

  it "captures the exist field on a service_exist event" do
    ActiveStorage::Current.url_options = { host: "example.com" }
    widget = Widget.create!(name: "storage widget")
    widget.photo.attach(io: StringIO.new("bytes"), filename: "p.png", content_type: "image/png")

    Railwatch.start_execution(source: :command, sample_kind: :commands)
    widget.photo.blob.service.exist?(widget.photo.blob.key)
    Railwatch.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)

    exist = railwatch_records(:storage_op).sole
    expect(exist[:op]).to eq("exist")
    expect(exist[:exist]).to be(true)
  end
end
