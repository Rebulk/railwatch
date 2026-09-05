# frozen_string_literal: true

require "spec_helper"

RSpec.describe Lantern::JobTracing, type: :request do
  it "round-trips lantern_trace_id and lantern_parent_id through serialize/deserialize" do
    job = WidgetJob.new("hello")
    job.lantern_trace_id = "trace-abc"
    job.lantern_parent_id = "parent-xyz"

    data = job.serialize
    expect(data["lantern_trace_id"]).to eq("trace-abc")
    expect(data["lantern_parent_id"]).to eq("parent-xyz")

    loaded = WidgetJob.new
    loaded.deserialize(data)
    expect(loaded.lantern_trace_id).to eq("trace-abc")
    expect(loaded.lantern_parent_id).to eq("parent-xyz")
  end

  it "round-trips lantern_user and lantern_tenant through serialize/deserialize" do
    job = WidgetJob.new("hello")
    job.lantern_user = "acme:7"
    job.lantern_tenant = "acme"

    data = job.serialize
    expect(data["lantern_user"]).to eq("acme:7")
    expect(data["lantern_tenant"]).to eq("acme")

    loaded = WidgetJob.new
    loaded.deserialize(data)
    expect(loaded.lantern_user).to eq("acme:7")
    expect(loaded.lantern_tenant).to eq("acme")
  end

  it "omits lantern_user and lantern_tenant entirely when there is no identity to carry" do
    data = WidgetJob.new("hello").serialize

    expect(data).not_to have_key("lantern_user")
    expect(data).not_to have_key("lantern_tenant")
  end

  it "falls back to the current execution's trace_id/id when not explicitly set" do
    exe = Lantern.start_execution(source: :command, sample_kind: :commands)
    job = WidgetJob.new("hello")

    data = job.serialize

    expect(data["lantern_trace_id"]).to eq(exe.trace_id)
    expect(data["lantern_parent_id"]).to eq(exe.id)
  ensure
    Lantern.finish_execution
  end

  it "links a job attempt's trace_id back to the request that enqueued it" do
    # Enqueue during the request, then drain the queue afterwards -- draining
    # *during* the request (perform_enqueued_jobs { get ... }) performs the
    # job inline while the request's execution is still Current, which the
    # perform.active_job subscriber's un-scoped `Current.execution = exe`
    # then clobbers, so the request never gets a Current execution to finish
    # against. That's a separate concern from what this example is testing.
    get "/enqueue"
    req = lantern_records(:request).sole

    perform_enqueued_jobs

    attempt = lantern_records(:job_attempt).sole
    expect(attempt[:trace_id]).to eq(req[:trace_id])
  end

  it "surfaces the enqueuing execution's id as parent_id on the shipped job_attempt record" do
    get "/enqueue"
    req = lantern_records(:request).sole

    perform_enqueued_jobs

    attempt = lantern_records(:job_attempt).sole
    expect(attempt[:parent_id]).to eq(req[:execution_id])
  end

  it "gives a job enqueued outside any execution a fresh trace_id of its own" do
    perform_enqueued_jobs { WidgetJob.perform_later("standalone") }

    attempt = lantern_records(:job_attempt).sole
    expect(attempt[:trace_id]).to be_a(String)
    expect(attempt[:trace_id]).not_to be_empty
  end

  describe "user and tenant propagation" do
    # Users.remember memoizes per user id on a module-level @seen hash that
    # outlives any single example.
    before { Lantern::Subscribers::Users.instance_variable_set(:@seen, {}) }

    # A tenant source the example can switch off, so "the worker sees no
    # tenant of its own" is a fact the assertions rest on rather than an
    # assumption about what leaks between a request and a drain.
    def stub_tenant(name)
      source = Class.new do
        class << self
          attr_accessor :current_tenant
        end
      end
      source.current_tenant = name
      stub_const("TenantRecord", source)
      source
    end

    # Everything this process could resolve locally, gone: whatever the job
    # is attributed to after this has to have come out of the payload.
    def forget_local_identity!(tenant_source)
      Current.user = nil
      tenant_source.current_tenant = nil
    end

    it "attributes a job attempt and its child records to the user and tenant of the request that enqueued it" do
      User.create!(name: "Ada", email: "ada@example.com")
      tenant = stub_tenant("acme")

      get "/enqueue"
      forget_local_identity!(tenant)
      perform_enqueued_jobs

      attempt = lantern_records(:job_attempt).sole
      expect(attempt[:user]).to eq("acme:1")
      expect(attempt[:tenant]).to eq("acme")

      query = lantern_records(:query).find { |q| q[:execution_id] == attempt[:attempt_id] }
      expect(query[:user]).to eq("acme:1")
      expect(query[:tenant]).to eq("acme")
    end

    it "carries the same originating identity through a job that enqueues another job" do
      User.create!(name: "Ada", email: "ada@example.com")
      tenant = stub_tenant("acme")
      Current.user = User.first

      Lantern.start_execution(source: :command, sample_kind: :commands)
      ChainedJob.perform_later
      Lantern.finish_execution

      forget_local_identity!(tenant)
      perform_enqueued_jobs # ChainedJob, which enqueues WidgetJob
      perform_enqueued_jobs # WidgetJob

      attempt = lantern_records(:job_attempt).find { |a| a[:name] == "WidgetJob" }
      expect(attempt[:user]).to eq("acme:1")
      expect(attempt[:tenant]).to eq("acme")
    end

    it "qualifies a propagated user on the worker when the tenant bound after resolution" do
      User.create!(name: "Ada", email: "ada@example.com")
      tenant = stub_tenant(nil)
      Current.user = User.first

      exe = Lantern.start_execution(source: :command, sample_kind: :commands)
      exe.user_id = Lantern::Subscribers::Users.resolve_from_current
      expect(exe.user_id).to eq("1")

      tenant.current_tenant = "acme"
      WidgetJob.perform_later("hello")
      Lantern.finish_execution

      forget_local_identity!(tenant)
      perform_enqueued_jobs

      attempt = lantern_records(:job_attempt).sole
      expect(attempt[:user]).to eq("acme:1")
      expect(attempt[:tenant]).to eq("acme")
    ensure
      Current.user = nil
    end

    it "falls back to local resolution for a payload enqueued before these keys existed" do
      User.create!(name: "Ada", email: "ada@example.com")
      get "/enqueue"
      queued = ActiveJob::Base.queue_adapter.enqueued_jobs.sole
      queued.delete("lantern_user")
      queued.delete("lantern_tenant")
      Current.user = User.first

      perform_enqueued_jobs

      attempt = lantern_records(:job_attempt).sole
      expect(attempt[:user]).to eq("1")
      expect(attempt[:tenant]).to be_nil
    ensure
      Current.user = nil
    end

    it "resolves the user locally for an inline perform_now, which never serializes" do
      User.create!(name: "Ada", email: "ada@example.com")
      Current.user = User.first

      WidgetJob.perform_now("hello")

      expect(lantern_records(:job_attempt).sole[:user]).to eq("1")
    ensure
      Current.user = nil
    end
  end
end
