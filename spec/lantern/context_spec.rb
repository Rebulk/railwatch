# frozen_string_literal: true

require "spec_helper"

RSpec.describe Lantern::Context do
  after do
    ActiveSupport::ExecutionContext.clear
    Rails.event.clear_context
  end

  describe ".set / .current" do
    it "writes attrs to ActiveSupport::ExecutionContext so .current reflects them" do
      Lantern.context(section: "checkout", order_id: 42)
      expect(described_class.current).to include(section: "checkout", order_id: 42)
    end
  end

  describe ".serialized" do
    it "returns the empty JSON object when no context has been set" do
      expect(described_class.serialized).to eq("{}")
    end

    it "JSON-encodes whatever .current returns" do
      Lantern.context(section: "checkout")
      expect(JSON.parse(described_class.serialized)).to eq("section" => "checkout")
    end

    it "truncates to 64KB instead of shipping an unbounded payload" do
      Lantern.context(blob: "x" * 100_000)
      json = described_class.serialized
      expect(json.bytesize).to eq(described_class::LIMIT)
    end
  end

  describe ".snapshot / .with" do
    it "uses the captured request context without mutating the consumer thread" do
      tenant_record = Class.new do
        def self.current_tenant
          Thread.current[:lantern_context_spec_tenant]
        end
      end
      stub_const("TenantRecord", tenant_record)
      Thread.current[:lantern_context_spec_tenant] = "request-tenant"
      Lantern.context(request_id: "request-value")
      snapshot = described_class.snapshot
      seen = Queue.new

      worker = Thread.new do
        Thread.current[:lantern_context_spec_tenant] = "worker-tenant"
        ActiveSupport::ExecutionContext.set(worker_secret: "preserved")
        described_class.with(snapshot) do
          Lantern.context(stream_phase: "body")
          seen << [ described_class.current, described_class.current_tenant,
                    ActiveSupport::ExecutionContext.to_h ]
        end
        seen << [ described_class.current, described_class.current_tenant,
                  ActiveSupport::ExecutionContext.to_h ]
      ensure
        ActiveSupport::ExecutionContext.clear
        Thread.current[:lantern_context_spec_tenant] = nil
      end
      worker.join

      inside, outside = 2.times.map { seen.pop }
      expect(inside[0]).to include(request_id: "request-value", stream_phase: "body")
      expect(inside[0]).not_to include(:worker_secret)
      expect(inside[1]).to eq("request-tenant")
      expect(inside[2]).to include(worker_secret: "preserved")
      expect(outside[0]).to include(worker_secret: "preserved")
      expect(outside[1]).to eq("worker-tenant")
    ensure
      Thread.current[:lantern_context_spec_tenant] = nil
    end
  end

  describe "flowing into a parent record's context field" do
    it "attaches the current context to the execution's parent record" do
      Lantern.start_execution(source: :command, sample_kind: :commands)
      Lantern.context(section: "checkout")
      Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
      cmd = lantern_records(:command).sole
      expect(JSON.parse(cmd[:context])).to eq("section" => "checkout")
    end
  end

  describe ".current_tenant" do
    it "returns nil when no tenant provider is defined" do
      expect(described_class.current_tenant).to be_nil
    end

    it "reads TenantRecord.current_tenant when TenantRecord is defined" do
      tenant_record = Class.new do
        def self.current_tenant = "acme"
      end
      stub_const("TenantRecord", tenant_record)
      expect(described_class.current_tenant).to eq("acme")
    end

    it "returns nil instead of raising when the tenant provider errors" do
      tenant_record = Class.new do
        def self.current_tenant = raise("no tenant in this context")
      end
      stub_const("TenantRecord", tenant_record)
      expect(described_class.current_tenant).to be_nil
    end
  end
end
