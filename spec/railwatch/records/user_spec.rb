# frozen_string_literal: true

require "spec_helper"

RSpec.describe "user record", type: :request do
  def finish!
    Railwatch.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
  end

  # Users.remember memoizes per user id on a module-level @seen hash that
  # outlives any single example, so every example here starts from a clean
  # slate rather than being silently deduped by a previous example's user.
  before { Railwatch::Subscribers::Users.instance_variable_set(:@seen, {}) }

  it "resolves id, name, and email from Current.user by default" do
    User.create!(name: "Ada", email: "ada@example.com")
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    get "/widgets" # ApplicationController sets Current.user = User.first
    finish!

    user = railwatch_records(:user).sole
    expect(user[:id]).to eq("1")
    expect(user[:name]).to eq("Ada")
    expect(user[:email]).to eq("ada@example.com")
    expect(user[:tenant]).to be_nil
  end

  it "ships only one user record across two requests from the same user within the hour" do
    User.create!(name: "Ada", email: "ada@example.com")
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    get "/widgets"
    get "/widgets"
    finish!

    expect(railwatch_records(:user).size).to eq(1)
  end

  it "does not cache a user whose first resolution is sampled out" do
    details = { id: "sampled-user", name: "Ada", email: "ada@example.com" }
    exe = Railwatch.start_execution(source: :command, sample_kind: :commands)
    exe.sampled = false
    Railwatch::Subscribers::Users.remember(details)
    finish!

    Railwatch.start_execution(source: :command, sample_kind: :commands)
    Railwatch::Subscribers::Users.remember(details)
    finish!

    expect(railwatch_records(:user).map { |record| record[:id] }).to eq([ "sampled-user" ])
  end

  it "does not cache a buffered user when controller-level sampling later drops the execution" do
    details = { id: "late-sampled-user", name: "Ada", email: "ada@example.com" }
    exe = Railwatch.start_execution(source: :command, sample_kind: :commands)
    Railwatch::Subscribers::Users.remember(details)
    exe.sampled = false
    finish!

    Railwatch.start_execution(source: :command, sample_kind: :commands)
    Railwatch::Subscribers::Users.remember(details)
    finish!

    expect(railwatch_records(:user).map { |record| record[:id] }).to eq([ "late-sampled-user" ])
  end

  it "does not cache a user whose first resolution is paused" do
    details = { id: "paused-user", name: "Ada", email: "ada@example.com" }
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    Railwatch.pause
    Railwatch::Subscribers::Users.remember(details)
    Railwatch.resume
    finish!

    Railwatch.start_execution(source: :command, sample_kind: :commands)
    Railwatch::Subscribers::Users.remember(details)
    finish!

    expect(railwatch_records(:user).map { |record| record[:id] }).to eq([ "paused-user" ])
  end

  it "emits the same user again after fork state is reset" do
    details = { id: "fork-user", name: "Ada", email: "ada@example.com" }
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    Railwatch::Subscribers::Users.remember(details)
    finish!

    Railwatch::Subscribers::Users.restart_after_fork!
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    Railwatch::Subscribers::Users.remember(details)
    finish!

    expect(railwatch_records(:user).map { |record| record[:id] }).to eq([ "fork-user", "fork-user" ])
  end

  it "uses config.user's custom resolver block instead of the id/name/email default" do
    Railwatch.config.user { |u| { id: "custom-#{u.id}", name: "Custom #{u.name}", email: nil } }
    User.create!(name: "Bob", email: "bob@example.com")
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    get "/widgets"
    finish!

    user = railwatch_records(:user).sole
    expect(user[:id]).to eq("custom-1")
    expect(user[:name]).to eq("Custom Bob")
    expect(user[:email]).to be_nil
  ensure
    Railwatch.config.instance_variable_set(:@user_resolver, nil)
  end

  it "prefixes the resolved id with the current tenant when one is set" do
    tenant_record = Class.new { def self.current_tenant = "acme" }
    stub_const("TenantRecord", tenant_record)
    User.create!(name: "Carl", email: "carl@example.com")
    Railwatch.start_execution(source: :command, sample_kind: :commands)
    get "/widgets"
    finish!

    user = railwatch_records(:user).sole
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
      exe = Railwatch.start_execution(source: :command, sample_kind: :commands)
      exe.user_id = Railwatch::Subscribers::Users.resolve_from_current
      expect(exe.user_id).to eq("1")

      tenant_record.current_tenant = tenant
      finish!
    end

    expect(railwatch_records(:user).map { |record| [ record[:id], record[:tenant] ] })
      .to contain_exactly([ "acme:1", "acme" ], [ "beta:1", "beta" ])
    expect(railwatch_records(:command).map { |record| record[:user] })
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
      exe = Railwatch.start_execution(source: :command, sample_kind: :commands)
      exe.user_id = Railwatch::Subscribers::Users.resolve_from_current
      tenant_record.current_tenant = "acme"
      finish!
    end

    expect(railwatch_records(:user).map { |record| record[:id] }).to eq([ "acme:1" ])
    expect(railwatch_records(:command).map { |record| record[:user] }).to eq([ "acme:1", "acme:1" ])
  ensure
    Current.user = nil
  end
end
