# frozen_string_literal: true

require "spec_helper"

RSpec.describe "sampling", type: :request do
  before do
    3.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) }
  end

  it "ships nothing at all, not even logs, when the request is sampled out" do
    Railwatch.config.sample[:requests] = 0.0
    get "/widgets" # logs "listed N widgets" and runs several queries
    expect(response).to have_http_status(:ok)

    expect(railwatch_records).to be_empty
  end

  it "still ships an unhandled exception and its parent when sampled out but exceptions rate is 1.0" do
    Railwatch.config.sample[:requests] = 0.0
    Railwatch.config.sample[:exceptions] = 1.0
    get "/boom"

    ex = railwatch_records(:exception).sole
    expect(ex).to include(class: "ArgumentError", handled: false)

    req = railwatch_records(:request).sole
    expect(req[:status_code]).to eq(500)
    expect(railwatch_records(:query)).to be_empty
  end

  it "still ships an unhandled exception from a sampled-out request under backpressure" do
    Railwatch.config.sample[:requests] = 0.0
    Railwatch.config.sample[:exceptions] = 1.0
    Railwatch.reporter.instance_variable_set(:@backpressure_factor, 4.0)
    allow(Random).to receive(:rand).and_return(0.1)

    get "/boom"

    expect(railwatch_records(:exception).sole).to include(class: "ArgumentError", handled: false)
    expect(railwatch_records(:request).sole[:status_code]).to eq(500)
  ensure
    Railwatch.reporter.instance_variable_set(:@backpressure_factor, 1.0)
  end

  it "divides every configured sample rate by the reporter's backpressure factor" do
    Railwatch.config.sample[:requests] = 1.0
    Railwatch.reporter.instance_variable_set(:@backpressure_factor, 4.0)
    allow(Random).to receive(:rand).and_return(0.24, 0.25)

    expect(Railwatch::Sampler.decide(:requests)).to be(true)
    expect(Railwatch::Sampler.decide(:requests)).to be(false)
  ensure
    Railwatch.reporter.instance_variable_set(:@backpressure_factor, 1.0)
  end

  it "ships nothing for an unhandled exception when sampled out and exceptions rate is 0.0" do
    Railwatch.config.sample[:requests] = 0.0
    Railwatch.config.sample[:exceptions] = 0.0
    get "/boom"

    expect(railwatch_records(:exception)).to be_empty
    expect(railwatch_records(:request)).to be_empty
  end

  it "never ships a handled exception from a sampled-out request" do
    Railwatch.config.sample[:requests] = 0.0
    Railwatch.config.sample[:exceptions] = 1.0
    get "/handled"

    expect(railwatch_records(:exception)).to be_empty
    expect(railwatch_records(:request)).to be_empty
  end

  it "lets Railwatch.sample(rate) inside the request override the boot-time sampled-out decision" do
    Railwatch.config.sample[:requests] = 0.0
    get "/override_sample", params: { mode: "on" }

    expect(railwatch_records(:request).sole[:status_code]).to eq(200)
    expect(railwatch_records(:query)).not_to be_empty
  end

  it "lets Railwatch.dont_sample inside the request override a sampled-in boot decision" do
    Railwatch.config.sample[:requests] = 1.0
    get "/override_sample", params: { mode: "dont" }

    expect(railwatch_records).to be_empty
  end

  it "applies railwatch_sample only: to just the listed action, leaving other actions on the same controller sampled" do
    get "/sampled"
    expect(railwatch_records).to be_empty

    get "/widgets"
    expect(railwatch_records(:request)).not_to be_empty
  end

  describe "jobs, scheduled tasks, commands, and channels honour their own sample rate" do
    { job: :jobs, scheduled_task: :scheduled_tasks, command: :commands, channel_action: :channels }.each do |source, kind|
      it "samples a #{source} execution by config.sample[:#{kind}], independent of the request rate" do
        Railwatch.config.sample[:requests] = 0.0
        Railwatch.config.sample[kind] = 1.0
        exe = Railwatch.start_execution(source: source, sample_kind: kind)
        expect(exe.sampled?).to be(true)
        Railwatch.finish_execution

        Railwatch.config.sample[kind] = 0.0
        exe = Railwatch.start_execution(source: source, sample_kind: kind)
        expect(exe.sampled?).to be(false)
        Railwatch.finish_execution
      end
    end
  end
end
