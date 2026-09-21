# frozen_string_literal: true

require "spec_helper"

# Generates lib/railwatch/wire_fixtures.json: one record per type in
# Railwatch::Record::VERSIONS, produced by the gem's own subscribers and
# middleware, so a receiver can test its mapper against what the gem actually
# sends rather than what it remembers the gem sending.
#
# The checked-in file must equal a fresh generation. When a subscriber
# changes a record's shape, run `rake railwatch:wire_fixtures` and commit the
# result; that diff is the review surface for the wire change.
# What a few producers need that the dummy app does not set up on its own:
# Solid Queue's schema (scheduled_task), a Noticed delivery (notification),
# and a Puma server with queue stats to read (health).
module WireFixtureStubs
  def install_queue_schema
    return if SolidQueue::Record.connection.table_exists?("solid_queue_recurring_tasks")

    schema_path = Gem.find_files("generators/solid_queue/install/templates/db/queue_schema.rb").first
    SolidQueue::Record.connection.instance_eval(File.readlines(schema_path)[1..-2].join)
  end

  def stub_health_sources
    Railwatch::Execution.instance_variable_set(:@memory_sampled_at, 0.0)
    Railwatch::Health.remove_instance_variable(:@puma_server) if Railwatch::Health.instance_variable_defined?(:@puma_server)
    relation = Struct.new(:count)
    stub_const("Puma::Server", Class.new { def stats = { backlog: 3, running: 5, pool_capacity: 0, max_threads: 5, busy_threads: 4, requests_count: 1_234 } })
    stub_const("SolidQueue::ReadyExecution", Class.new {
      define_singleton_method(:count) { 7 }
      define_singleton_method(:minimum) { |_| Time.utc(2026, 9, 3, 12, 0, 0) }
      define_singleton_method(:group) { |_| relation.new({ "default" => 5, "urgent" => 2 }) }
    })
    stub_const("SolidQueue::Process", Class.new { define_singleton_method(:where) { |_| Struct.new(:count).new(2) } })
    @puma = Puma::Server.new
  end
end

# The same stand-in notification_spec defines, since Noticed is not a
# dependency; a separate class so neither file depends on load order.
module Noticed; end unless defined?(Noticed)
class Noticed::FixtureDelivery < ActiveJob::Base
  def perform(**) = nil
end

RSpec.describe "wire fixtures", type: :request do
  include ActiveJob::TestHelper
  include WireFixtureStubs

  # Notifications.install! subscribes every time it is called, and
  # notification_spec installs it too; a second subscription would produce
  # two records per delivery there. Install once per process, whoever loads first.
  before(:context) do
    $railwatch_notifications_installed ||= Railwatch::Subscribers::Notifications.install!(Rails.application) || true
  end

  # What changes between runs or machines is replaced by a stable stand-in
  # of the same type, so the file still exercises every column but only
  # churns when a subscriber changes what it sends. Timings and memory are
  # any number; identifiers are any token; the gem frames of a backtrace
  # and the versions in a process record depend on the machine.
  STABLE = {
    "timestamp" => 1_767_225_600.0, "execution_id" => "5c3b1e2a-9d4f-4a2b-8e1c-2f6a7b9c0d3e",
    "trace_id" => "8f14e45f-ceea-4b8f-8ac2-9a6e0c9f1a11", "pid" => 4242, "server" => "web-1", "deploy" => "3f9c2a1",
    "ruby_version" => "4.0.0", "rails_version" => "8.1.0", "railwatch_version" => "0.0.0"
  }.freeze
  NUMERIC = %w[duration db_runtime view_runtime queue_latency memory peak_memory gc_time drift boot_seconds
               started_at ended_at bytes cost interval samples stacks_bytes allocations
               middleware_before action render middleware_after].freeze
  TOKEN = %w[job_id provider_job_id attempt_id id message_id key stacks data].freeze

  def stabilize(value, key = nil)
    case value
    when Hash then value.to_h { |k, v| [ k, stabilize(v, k.to_s) ] }
    when Array then key == "frames" ? value.select { |f| f["in_app"] || f[:in_app] }.map { |f| stabilize(f) } : value.map { |v| stabilize(v, key) }
    when Numeric then STABLE.fetch(key) { NUMERIC.include?(key) ? 1 : value }
    when String then STABLE.fetch(key) { TOKEN.include?(key) ? "x" : stable_text(value) }
    else value
    end
  end

  def finish!
    Railwatch.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
  end

  def in_command
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    yield
  ensure
    finish!
  end

  def post_beacon(payload)
    post "/railwatch/beacon", params: payload.to_json, headers: { "Content-Type" => "application/json" }
  end

  # Every type, each block leaving at least one record of that type in the
  # transport. Kept in VERSIONS order so the file reads top to bottom.
  PRODUCERS = {
    request: -> { User.create!(name: "Ada", email: "ada@example.com"); get "/widgets" },
    job_attempt: -> { WidgetJob.perform_now("bob") },
    scheduled_task: -> {
      install_queue_schema
      job = WidgetJob.new("bob")
      task = SolidQueue::RecurringTask.create!(key: "widget_recurring", class_name: job.class.name, schedule: "*/5 * * * *", static: true)
      sq_job = SolidQueue::Job.create!(queue_name: job.queue_name, class_name: job.class.name, active_job_id: job.job_id, priority: 0)
      SolidQueue::RecurringExecution.create!(task_key: task.key, run_at: Time.current, job_id: sq_job.id)
      Railwatch::Subscribers::Jobs.refresh_recurring_tasks!
      job.perform_now
    },
    command: -> { in_command { Widget.create!(name: "from_command") } },
    channel_action: -> {
      Railwatch.start_execution(source: :channel_action, sample_kind: :requests)
      Railwatch.finish_execution(:channel_action, group: "WidgetChannel#observed", channel: "WidgetChannel",
                                 action: "observed", status: "processed", failed: false)
    },
    query: -> { in_command { Widget.where(name: "x").to_a } },
    n_plus_one: -> {
      Railwatch.config.n_plus_one_threshold = 3
      4.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) }
      get "/widgets"
    },
    transaction: -> { in_command { ActiveRecord::Base.transaction { Widget.create!(name: "t") } } },
    exception: -> { get "/boom" },
    cache_event: -> { in_command { Rails.cache.write("a", 1, expires_in: 60) } },
    mail: -> { get "/mail" },
    broadcast: -> { in_command { ActionCable.server.broadcast("widgets:42:updates", { foo: "bar" }) } },
    notification: -> { in_command { Noticed::FixtureDelivery.perform_now(notification_class: "WelcomeNotification") } },
    outgoing_request: -> {
      stub_request(:get, "http://example.test/widgets").to_return(status: 200, body: "ok")
      in_command { Net::HTTP.get(URI("http://example.test/widgets?secret=1")) }
    },
    storage_op: -> { Widget.create!(name: "storage widget"); get "/storage" },
    view_render: -> { Gadget.create!(name: "g"); get "/many" },
    log: -> { in_command { Rails.logger.info("hello world") } },
    enqueued_job: -> { in_command { WidgetJob.perform_later("bob") } },
    user: -> {
      # Users.remember memoizes per id for the process; the request producer
      # above already saw Ada, so forget her the way user_spec does.
      Railwatch::Subscribers::Users.instance_variable_set(:@seen, {})
      User.create!(name: "Ada", email: "ada@example.com")
      get "/widgets"
    },
    deprecation: -> {
      deprecator = ActiveSupport::Deprecation.new("2.0", "Rails")
      deprecator.behavior = :notify
      in_command { deprecator.warn("old_method is deprecated") }
    },
    visit: -> {
      post_beacon(visits: [ { component: "Widgets/Index", url: "/widgets", method: "GET", started_at: Time.now.to_f * 1000,
                              duration_ms: 12.5, status: "200", partial: false, props_bytes: 42 } ])
    },
    process: -> { Railwatch::Subscribers::ProcessInfo.install!(Rails.application); Railwatch::Subscribers::ProcessInfo.record! },
    span: -> { in_command { Railwatch.span("pdf.render", vendor: "prawn") { :done } } },
    health: -> { stub_health_sources; Railwatch::Health.sample },
    profile: -> {
      Gadget.create!(name: "g").then { |g| 40.times { |i| Widget.create!(name: "w#{i}", gadget: g) } }
      Railwatch.config.profile_interval_us = 200
      Railwatch.config.profile_sample = 1.0
      get "/widgets"
    },
    attachment: -> {
      error = begin; raise "invoice render failed"; rescue RuntimeError => e; e; end
      # Grouped by an explicit fingerprint: the default groups by raising
      # frame, which is a line of this file.
      Railwatch.report(error, handled: true, fingerprint: [ "invoice-render" ])
      Railwatch.attach("payload.json", '{"order":1}', exception: error)
    },
    session: -> { post_beacon(visits: [], session: { id: "s1", started_at: (Time.now.to_f - 60) * 1000 }) },
    llm_call: -> {
      tokens = Struct.new(:input, :output, :cache_read, :cache_write, :thinking, :reported_cost, keyword_init: true)
      cost = Struct.new(:total, keyword_init: true)
      message = Struct.new(:role, :content, keyword_init: true)
      in_command do
        ActiveSupport::Notifications.instrument("chat.ruby_llm",
          chat: nil, provider: "anthropic", model: "claude-opus-5",
          input_messages: [ message.new(role: :user, content: "How many tons?") ], message_count: 1, tools: [],
          streaming: false, tokens: tokens.new(input: 12, output: 3, cache_read: 0, cache_write: 0, thinking: 0),
          cost: cost.new(total: 0.0001), response_model: "claude-opus-5") { nil }
      end
    }
  }.freeze

  # A source location inside this file names a line that moves whenever the
  # file is edited, so it is reduced to the file. Object addresses and
  # machine paths likewise.
  def stable_text(value)
    value.sub(Dir.pwd, "").sub(Gem.dir, "GEM_DIR").gsub(/0x[0-9a-f]{8,}/, "0x0")
         .gsub(%r{(/spec/railwatch/wire_fixtures_spec\.rb):\d+}, "\\1")
  end

  def generate
    PRODUCERS.to_h do |type, produce|
      railwatch_transport.batches.clear
      instance_exec(&produce)
      record = railwatch_records(type).first or raise "producer for #{type} left no #{type} record"
      [ type.to_s, stabilize(JSON.parse(JSON.generate(record))) ]
    end
  end

  after do
    Railwatch.config.n_plus_one_threshold = 5
    Railwatch.config.profile_sample = 0.0
  end

  it "covers every record type the gem can emit, at its current version" do
    generated = generate
    expect(generated.keys).to match_array(Railwatch::Record::VERSIONS.keys.map(&:to_s))
    generated.each { |type, record| expect(record["v"]).to eq(Railwatch::Record::VERSIONS.fetch(type.to_sym)), type }
  end

  it "matches the shipped lib/railwatch/wire_fixtures.json (run `rake railwatch:wire_fixtures` after a wire change)" do
    if ENV["RAILWATCH_WRITE_WIRE_FIXTURES"]
      File.write(Railwatch.wire_fixtures_path, JSON.pretty_generate(generate) + "\n")
      skip "wrote #{Railwatch.wire_fixtures_path}"
    end
    expect(generate).to eq(Railwatch.wire_fixtures)
  end
end
