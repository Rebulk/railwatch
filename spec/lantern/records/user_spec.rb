# frozen_string_literal: true

require "spec_helper"

RSpec.describe "user record", type: :request do
  def finish!
    Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
  end

  # Users.remember memoizes per user id on a module-level @seen hash that
  # outlives any single example, so every example here starts from a clean
  # slate rather than being silently deduped by a previous example's user.
  before { Lantern::Subscribers::Users.instance_variable_set(:@seen, {}) }

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
end
