# frozen_string_literal: true

require "spec_helper"

RSpec.describe Nightrail::Context do
  after do
    ActiveSupport::ExecutionContext.clear
    Rails.event.clear_context
  end

  describe ".set / .current" do
    it "writes attrs to ActiveSupport::ExecutionContext so .current reflects them" do
      Nightrail.context(section: "checkout", order_id: 42)
      expect(described_class.current).to include(section: "checkout", order_id: 42)
    end
  end

  describe ".serialized" do
    it "returns the empty JSON object when no context has been set" do
      expect(described_class.serialized).to eq("{}")
    end

    it "JSON-encodes whatever .current returns" do
      Nightrail.context(section: "checkout")
      expect(JSON.parse(described_class.serialized)).to eq("section" => "checkout")
    end

    it "recursively applies the same Nightrail and Rails parameter filters as request params" do
      Nightrail.context(
        account: {
          password: "hunter2",
          profile: [ { secret_code: "rails-secret", display_name: "Ada" } ]
        }
      )

      context = JSON.parse(described_class.serialized)

      expect(context.dig("account", "password")).to eq("[FILTERED]")
      expect(context.dig("account", "profile", 0, "secret_code")).to eq("[FILTERED]")
      expect(context.dig("account", "profile", 0, "display_name")).to eq("Ada")
    end

    it "stays inside 64KB and stays parseable when one value is oversized" do
      Nightrail.context(section: "checkout", blob: "x" * 100_000)

      json = described_class.serialized

      expect(json.bytesize).to be <= described_class::LIMIT
      context = JSON.parse(json)
      expect(context["_nightrail_truncated"]).to be(true)
      expect(context["section"]).to eq("checkout")
      expect(context["blob"]).to end_with("[TRUNCATED]")
    end

    it "stays parseable when the context is oversized because of the number of keys" do
      Nightrail.context(**2_000.times.to_h { |i| [ :"key_#{i}", "v" * 100 ] })

      json = described_class.serialized

      expect(json.bytesize).to be <= described_class::LIMIT
      context = JSON.parse(json)
      expect(context["_nightrail_truncated"]).to be(true)
      expect(context.size).to be_between(2, 2_000)
      expect(context["key_0"]).to eq("v" * 100)
    end

    it "redacts before measuring, so a filtered secret cannot be the reason a context truncates" do
      Nightrail.context(password: "x" * 100_000, section: "checkout")

      context = JSON.parse(described_class.serialized)

      expect(context["password"]).to eq("[FILTERED]")
      expect(context["section"]).to eq("checkout")
      expect(context).not_to have_key("_nightrail_truncated")
    end
  end

  describe "flowing into a parent record's context field" do
    it "attaches the current context to the execution's parent record" do
      Nightrail.start_execution(source: :command, sample_kind: :commands)
      Nightrail.context(section: "checkout")
      Nightrail.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
      cmd = nightrail_records(:command).sole
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

    it "binds a tenant set through Nightrail.context onto the running execution" do
      exe = Nightrail.start_execution(source: :command, sample_kind: :commands)

      Nightrail.context(tenant: "custom-acme")

      expect(exe.tenant).to eq("custom-acme")
      expect(described_class.current_tenant).to eq("custom-acme")
    ensure
      Nightrail.finish_execution
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
