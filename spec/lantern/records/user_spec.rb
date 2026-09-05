# frozen_string_literal: true

require "spec_helper"

RSpec.describe "user record", type: :request do
  def finish!
    Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
  end

  # Users.remember memoizes per user id on a module-level @seen hash that
  # outlives any single example, so every example here starts from a clean
  # slate rather than being silently deduped by a previous example's user.
  before { Lantern::Subscribers::Users.restart_after_fork! }

  it "resolves id, name, and email from Current.user by default" do
    User.create!(name: "Ada", email: "ada@example.com")
    Lantern.start_execution(source: :command, sample_kind: :commands)
    get "/widgets" # ApplicationController sets Current.user = User.first
    finish!

    user = lantern_records(:user).sole
    expect(user[:id]).to eq("1")
    expect(user[:name]).to eq("Ada")
    expect(user[:email]).to eq("ada@example.com")
    expect(user[:tenant]).to be_nil
  end

  it "ships only one user record across two requests from the same user within the hour" do
    User.create!(name: "Ada", email: "ada@example.com")
    Lantern.start_execution(source: :command, sample_kind: :commands)
    get "/widgets"
    get "/widgets"
    finish!

    expect(lantern_records(:user).size).to eq(1)
  end

  it "does not cache a user whose first resolution is sampled out" do
    details = { id: "sampled-user", name: "Ada", email: "ada@example.com" }
    exe = Lantern.start_execution(source: :command, sample_kind: :commands)
    exe.sampled = false
    Lantern::Subscribers::Users.remember(details)
    finish!

    Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern::Subscribers::Users.remember(details)
    finish!

    expect(lantern_records(:user).map { |record| record[:id] }).to eq([ "sampled-user" ])
  end

  it "does not cache a buffered user when controller-level sampling later drops the execution" do
    details = { id: "late-sampled-user", name: "Ada", email: "ada@example.com" }
    exe = Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern::Subscribers::Users.remember(details)
    exe.sampled = false
    finish!

    Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern::Subscribers::Users.remember(details)
    finish!

    expect(lantern_records(:user).map { |record| record[:id] }).to eq([ "late-sampled-user" ])
  end

  it "emits one user record across nested executions" do
    details = { id: "nested-user", name: "Ada", email: "ada@example.com" }
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern::Subscribers::Users.remember(details)

    Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern::Subscribers::Users.remember(details)
    finish!
    finish!

    expect(lantern_records(:user).map { |record| record[:id] }).to eq([ "nested-user" ])
  end

  it "emits one user record across concurrently finishing executions" do
    details = { id: "concurrent-user", name: "Ada", email: "ada@example.com" }
    ready = Queue.new
    release = Queue.new
    threads = 2.times.map do
      Thread.new do
        Lantern.start_execution(source: :command, sample_kind: :commands)
        Lantern::Subscribers::Users.remember(details)
        ready << true
        release.pop
        finish!
      end
    end

    2.times { ready.pop }
    2.times { release << true }
    threads.each(&:value)

    expect(lantern_records(:user).map { |record| record[:id] }).to eq([ "concurrent-user" ])
  end

  it "deduplicates concurrent records by their final late-bound tenant reference" do
    details = { id: "1", name: "Ada", email: "ada@example.com" }
    ready = Queue.new
    release = Queue.new
    threads = 2.times.map do
      Thread.new do
        exe = Lantern.start_execution(source: :command, sample_kind: :commands)
        Lantern::Subscribers::Users.remember(details)
        exe.tenant = "acme"
        ready << true
        release.pop
        finish!
      end
    end

    2.times { ready.pop }
    2.times { release << true }
    threads.each(&:value)

    expect(lantern_records(:user).map { |record| [ record[:id], record[:tenant] ] })
      .to eq([ [ "acme:1", "acme" ] ])
  end

  it "keeps buffered byte weights aligned after removing a late-bound duplicate" do
    details = { id: "1", name: "Ada", email: "ada@example.com" }
    first = Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern::Subscribers::Users.remember(details)
    first.tenant = "acme"
    finish!

    second = Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern::Subscribers::Users.remember(details)
    second.tenant = "acme"
    log = Lantern.record(:log, level: "info", message: "kept")
    claims = Lantern::Subscribers::Users.prepare_execution!(second)
    buffered = []
    second.each_record { |record, bytes| buffered << [ record, bytes ] }

    expect(buffered).to eq([ [ log, Lantern::Record.buffered_bytes(log, limit: Lantern.config.execution_buffer_bytes) ] ])
    Lantern::Subscribers::Users.release_execution!(claims)
    claims = nil
    finish!
  ensure
    Lantern::Subscribers::Users.release_execution!(claims)
  end

  it "does not deduplicate the same raw id across different late-bound tenants" do
    details = { id: "1", name: "Ada", email: "ada@example.com" }
    ready = Queue.new
    release = Queue.new
    threads = %w[acme beta].map do |tenant|
      Thread.new do
        exe = Lantern.start_execution(source: :command, sample_kind: :commands)
        Lantern::Subscribers::Users.remember(details)
        exe.tenant = tenant
        ready << true
        release.pop
        finish!
      end
    end

    2.times { ready.pop }
    2.times { release << true }
    threads.each(&:value)

    expect(lantern_records(:user).map { |record| [ record[:id], record[:tenant] ] })
      .to contain_exactly([ "acme:1", "acme" ], [ "beta:1", "beta" ])
  end

  it "does not deadlock when concurrent executions observe users in opposite orders" do
    users = [
      { id: "first-user", name: "Ada", email: "ada@example.com" },
      { id: "second-user", name: "Grace", email: "grace@example.com" }
    ]
    ready = Queue.new
    release = Queue.new
    threads = [ users, users.reverse ].map do |ordered_users|
      Thread.new do
        Lantern.start_execution(source: :command, sample_kind: :commands)
        ordered_users.each { |details| Lantern::Subscribers::Users.remember(details) }
        ready << true
        release.pop
        finish!
      end
    end

    2.times { ready.pop }
    2.times { release << true }
    expect(threads.map { |thread| thread.join(2) }).to all(be_a(Thread))
    threads.each(&:value)

    expect(lantern_records(:user).map { |record| record[:id] }.sort).to eq(%w[first-user second-user])
  ensure
    threads&.each(&:kill)
  end

  it "releases a shared user after every overlapping execution is discarded" do
    details = { id: "discarded-user", name: "Ada", email: "ada@example.com" }
    outer = Lantern.start_execution(source: :command, sample_kind: :commands)
    outer.sampled = false
    Lantern::Subscribers::Users.remember(details)

    inner = Lantern.start_execution(source: :command, sample_kind: :commands)
    inner.sampled = false
    Lantern::Subscribers::Users.remember(details)
    finish!
    finish!

    Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern::Subscribers::Users.remember(details)
    finish!

    expect(lantern_records(:user).map { |record| record[:id] }).to eq([ "discarded-user" ])
  end

  it "releases the reservation when reporter handoff raises" do
    details = { id: "retry-user", name: "Ada", email: "ada@example.com" }
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern::Subscribers::Users.remember(details)
    allow(Lantern.reporter).to receive(:write).and_raise("reporter failed")

    expect { finish! }.to raise_error("reporter failed")

    allow(Lantern.reporter).to receive(:write).and_call_original
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern::Subscribers::Users.remember(details)
    finish!

    expect(lantern_records(:user).map { |record| record[:id] }).to eq([ "retry-user" ])
  end

  it "does not cache a user whose first resolution is paused" do
    details = { id: "paused-user", name: "Ada", email: "ada@example.com" }
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern.pause
    Lantern::Subscribers::Users.remember(details)
    Lantern.resume
    finish!

    Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern::Subscribers::Users.remember(details)
    finish!

    expect(lantern_records(:user).map { |record| record[:id] }).to eq([ "paused-user" ])
  end

  it "emits the same user again after fork state is reset" do
    details = { id: "fork-user", name: "Ada", email: "ada@example.com" }
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern::Subscribers::Users.remember(details)
    finish!

    Lantern::Subscribers::Users.restart_after_fork!
    Lantern.start_execution(source: :command, sample_kind: :commands)
    Lantern::Subscribers::Users.remember(details)
    finish!

    expect(lantern_records(:user).map { |record| record[:id] }).to eq([ "fork-user", "fork-user" ])
  end

  it "uses config.user's custom resolver block instead of the id/name/email default" do
    Lantern.config.user { |u| { id: "custom-#{u.id}", name: "Custom #{u.name}", email: nil } }
    User.create!(name: "Bob", email: "bob@example.com")
    Lantern.start_execution(source: :command, sample_kind: :commands)
    get "/widgets"
    finish!

    user = lantern_records(:user).sole
    expect(user[:id]).to eq("custom-1")
    expect(user[:name]).to eq("Custom Bob")
    expect(user[:email]).to be_nil
  ensure
    Lantern.config.instance_variable_set(:@user_resolver, nil)
  end

  it "prefixes the resolved id with the current tenant when one is set" do
    tenant_record = Class.new { def self.current_tenant = "acme" }
    stub_const("TenantRecord", tenant_record)
    User.create!(name: "Carl", email: "carl@example.com")
    Lantern.start_execution(source: :command, sample_kind: :commands)
    get "/widgets"
    finish!

    user = lantern_records(:user).sole
    expect(user[:id]).to eq("acme:1")
    expect(user[:tenant]).to eq("acme")
  end

  it "keeps the same numeric raw id distinct across two tenants that bind late" do
    tenant_record = Class.new do
      class << self
        attr_accessor :current_tenant
      end
    end
    stub_const("TenantRecord", tenant_record)
    Current.user = User.create!(name: "Ada", email: "ada@example.com")

    %w[acme beta].each do |tenant|
      tenant_record.current_tenant = nil
      exe = Lantern.start_execution(source: :command, sample_kind: :commands)
      exe.user_id = Lantern::Subscribers::Users.resolve_from_current
      expect(exe.user_id).to eq("1")

      tenant_record.current_tenant = tenant
      finish!
    end

    expect(lantern_records(:user).map { |record| [ record[:id], record[:tenant] ] })
      .to contain_exactly([ "acme:1", "acme" ], [ "beta:1", "beta" ])
    expect(lantern_records(:command).map { |record| record[:user] })
      .to contain_exactly("acme:1", "beta:1")
  ensure
    Current.user = nil
  end

  it "ships one entity, not one per request, when the same tenant binds late twice" do
    tenant_record = Class.new do
      class << self
        attr_accessor :current_tenant
      end
    end
    stub_const("TenantRecord", tenant_record)
    Current.user = User.create!(name: "Ada", email: "ada@example.com")

    2.times do
      tenant_record.current_tenant = nil
      exe = Lantern.start_execution(source: :command, sample_kind: :commands)
      exe.user_id = Lantern::Subscribers::Users.resolve_from_current
      tenant_record.current_tenant = "acme"
      finish!
    end

    expect(lantern_records(:user).map { |record| record[:id] }).to eq([ "acme:1" ])
    expect(lantern_records(:command).map { |record| record[:user] }).to eq([ "acme:1", "acme:1" ])
  ensure
    Current.user = nil
  end
end
