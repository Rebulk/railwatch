# frozen_string_literal: true

require "spec_helper"

RSpec.describe "profile record", type: :request do
  before do
    # Enough widgets that the controller's N+1 runs for several milliseconds,
    # so a 200µs sampling interval has plenty to catch.
    gadget = Gadget.create!(name: "g")
    40.times { |i| Widget.create!(name: "w#{i}", gadget: gadget) }
    Railwatch.config.profile_interval_us = 200
    # One unprofiled request first: otherwise the profile is mostly Zeitwerk
    # autoloading the app, not the app itself. Its records are dropped so the
    # examples below still see exactly one request.
    get "/widgets"
    Railwatch.flush
    railwatch_transport.batches.clear
  end

  after do
    Railwatch.config.profile_sample = 0.0
    Railwatch.config.profile_slow_ms = nil
    Railwatch.config.profile_interval_us = 1_000
    Railwatch.config.profiler = nil
    Railwatch::Profiler.reset!
  end

  def stacks_of(record)
    Zlib.gunzip(Base64.strict_decode64(record[:stacks]))
  end

  it "ships one v1 profile for a request when every request is profiled" do
    Railwatch.config.profile_sample = 1.0
    get "/widgets"

    profile = railwatch_records(:profile).sole
    expect(profile[:v]).to eq(1)
    expect(profile[:t]).to eq("profile")
    expect(profile[:profiler]).to eq("vernier")
    expect(profile[:mode]).to eq("wall")
    expect(profile[:interval]).to eq(200)
    expect(profile[:duration]).to be_positive
    expect(profile[:samples]).to be_positive
  end

  it "carries the request's envelope, so the profile joins its execution" do
    Railwatch.config.profile_sample = 1.0
    get "/widgets"

    profile = railwatch_records(:profile).sole
    expect(profile[:execution_id]).to eq(railwatch_records(:request).sole[:execution_id])
    expect(profile[:execution_source]).to eq("request")
  end

  it "ships the collapsed stacks gzipped and base64-encoded, with the uncompressed size" do
    Railwatch.config.profile_sample = 1.0
    get "/widgets"

    profile = railwatch_records(:profile).sole
    stacks = stacks_of(profile)
    expect(stacks.bytesize).to eq(profile[:stacks_bytes])
    expect(profile[:stacks].bytesize).to be < stacks.bytesize
    expect(stacks.lines).to all(match(/\A\S.* \d+\n\z/))
    # Rails' own stacks are deep enough that a request's collapsed text hits
    # the cap, so the counts that survive sum to at most `samples`.
    expect(stacks.bytesize).to be <= Railwatch::Profiler::MAX_COLLAPSED_BYTES
    expect(stacks.lines.sum { |line| line.split(" ").last.to_i }).to be_between(1, profile[:samples])
  end

  it "names the dummy app's own controller frame in the collapsed stacks" do
    Railwatch.config.profile_sample = 1.0
    get "/widgets"

    expect(stacks_of(railwatch_records(:profile).sole))
      .to include("WidgetsController#index (app/controllers/widgets_controller.rb:")
  end

  it "marks the request record as profiled" do
    Railwatch.config.profile_sample = 1.0
    get "/widgets"

    expect(railwatch_records(:request).sole[:profiled]).to be(true)
  end

  it "profiles with stackprof when config.profiler pins it" do
    Railwatch.config.profile_sample = 1.0
    Railwatch.config.profiler = :stackprof
    get "/widgets"

    profile = railwatch_records(:profile).sole
    expect(profile[:profiler]).to eq("stackprof")
    expect(stacks_of(profile)).to include("WidgetsController#index (app/controllers/widgets_controller.rb:")
  end

  it "ships nothing and leaves the request unmarked when profile_sample is 0.0" do
    get "/widgets"

    expect(railwatch_records(:profile)).to be_empty
    expect(railwatch_records(:request).sole).not_to have_key(:profiled)
  end

  it "does not profile a sampled-out request, whose tree ships nothing anyway" do
    Railwatch.config.profile_sample = 1.0
    Railwatch.config.sample[:requests] = 0.0
    get "/widgets"

    expect(railwatch_records).to be_empty
  end

  it "still serves the request, unprofiled, when the backend raises" do
    Railwatch.config.profile_sample = 1.0
    allow(::Vernier).to receive(:start_profile).and_raise("no profiler for you")
    get "/widgets"

    expect(response).to have_http_status(:ok)
    expect(railwatch_records(:profile)).to be_empty
    expect(railwatch_records(:request).sole).not_to have_key(:profiled)
  end

  # Both backends are process-global, so a nested execution (a job performed
  # inline inside a request, say) cannot have a profile of its own.
  it "profiles only the outer execution when one execution nests inside another" do
    Railwatch.config.profile_sample = 1.0
    outer = Railwatch.start_execution(source: :command, sample_kind: :commands)
    inner = Railwatch.start_execution(source: :job, sample_kind: :jobs)

    expect(outer.profiler_handle).not_to be_nil
    expect(inner.profiler_handle).to be_nil
    expect(Railwatch::Profiler.skipped).to eq(1)

    Railwatch.finish_execution(:job_attempt, group: "g", name: "InnerJob", queue: "default")
    Railwatch.finish_execution(:command, group: "g", class: "Rake::Task", name: "outer",
                             command: "rake outer", exit_code: 0)

    expect(railwatch_records(:profile).sole[:execution_id]).to eq(outer.id)
  end
end
