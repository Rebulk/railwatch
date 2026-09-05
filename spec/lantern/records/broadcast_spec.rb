# frozen_string_literal: true

require "spec_helper"
require "action_cable/channel/test_case"

RSpec.describe "broadcast record" do
  def finish!
    Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)
  end

  it "captures kind broadcast, stream, byte size, and JSON coder for an ActionCable.server.broadcast" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    ActionCable.server.broadcast("widgets:42:updates", { foo: "bar" })
    finish!

    rec = lantern_records(:broadcast).sole
    expect(rec[:kind]).to eq("broadcast")
    expect(rec[:stream]).to eq("widgets:42:updates")
    # :bytes is computed from the raw message's Ruby #to_s, before the coder
    # JSON-encodes it for the wire -- not the same byte count as the encoded frame.
    expect(rec[:bytes]).to eq({ foo: "bar" }.to_s.bytesize)
    expect(rec[:coder]).to eq("ActiveSupport::JSON")
    expect(rec[:duration]).to be_a(Integer).and be >= 0
  end

  it "groups two streams that differ only by a numeric id under the same shape" do
    Lantern.start_execution(source: :command, sample_kind: :commands)
    ActionCable.server.broadcast("widgets:42:updates", "a")
    ActionCable.server.broadcast("widgets:99:updates", "b")
    finish!

    groups = lantern_records(:broadcast).map { |r| r[:_group] }.uniq
    expect(groups.size).to eq(1)
  end

  context "channel transmit and perform_action", type: :channel do
    tests WidgetChannel

    it "opens a production-shaped channel execution around the complete action" do
      widget = Widget.create!(name: "observed")
      subscribe
      perform :observed, "id" => widget.id

      parent = lantern_records(:channel_action).sole
      children = lantern_records.select { |r| r[:execution_id] == parent[:execution_id] && r[:t] != "channel_action" }
      expect(parent).to include(
        channel: "WidgetChannel", action: "observed", status: "processed", failed: false,
        execution_source: "channel_action", execution_preview: "WidgetChannel#observed"
      )
      expect(parent[:counters]).to include(queries: 1, logs: 1, broadcasts: 3)
      expect(children.map { |r| r[:t] }).to include("query", "log", "broadcast")
      expect(children.map { |r| r[:trace_id] }.uniq).to eq([ parent[:trace_id] ])
      expect(Lantern.execution).to be_nil
    end

    it "captures kind transmit with the channel class and byte size when a channel calls #transmit" do
      Lantern.start_execution(source: :command, sample_kind: :commands)
      subscribe
      perform :follow, "id" => 42
      finish!

      transmit_rec = lantern_records(:broadcast).find { |r| r[:kind] == "transmit" }
      expect(transmit_rec[:channel]).to eq("WidgetChannel")
      expect(transmit_rec[:bytes]).to eq({ status: "following", id: 42 }.to_s.bytesize)
    end

    it "captures kind perform_action with the channel class and action name" do
      Lantern.start_execution(source: :command, sample_kind: :commands)
      subscribe
      perform :follow, "id" => 42
      finish!

      action_rec = lantern_records(:broadcast).find { |r| r[:kind] == "perform_action" }
      expect(action_rec[:channel]).to eq("WidgetChannel")
      expect(action_rec[:action]).to eq("follow")
      expect(action_rec[:failed]).to be(false)
    end

    it "leaves no execution on the pooled worker when user resolution raises" do
      allow(Lantern::Subscribers::Users).to receive(:resolve_from_current).and_raise("resolver blew up")
      subscribe

      perform :follow, "id" => 42

      expect(Lantern.execution).to be_nil
      expect(lantern_records(:channel_action).sole).to include(channel: "WidgetChannel", action: "follow")
    end

    it "honours the channel-specific sample rate" do
      Lantern.config.sample[:channels] = 0.0
      subscribe
      perform :follow, "id" => 42

      expect(lantern_records(:channel_action)).to be_empty
      expect(lantern_records(:broadcast)).to be_empty
      expect(Lantern.execution).to be_nil
    end

    it "still ships an unhandled exception and its channel parent when the action is sampled out" do
      Lantern.config.sample[:channels] = 0.0
      Lantern.config.sample[:exceptions] = 1.0
      subscribe
      expect { perform :explode }.to raise_error(RuntimeError, "channel action failed")

      expect(lantern_records(:exception).sole[:execution_source]).to eq("channel_action")
      expect(lantern_records(:channel_action).sole).to include(status: "failed", failed: true)
      expect(lantern_records(:broadcast)).to be_empty
      expect(Lantern.execution).to be_nil
    end

    # Action Cable's worker rescues and logs a channel action that raises; it
    # never reaches Rails.error or a Rack middleware. Sentry reported these
    # through its own cable hook, so parity means catching them here.
    it "reports an exception raised inside a channel action as an unhandled application.action_cable error" do
      subscribe
      expect { perform :explode }.to raise_error(RuntimeError, "channel action failed")

      ex = lantern_records(:exception).sole
      parent = lantern_records(:channel_action).sole
      expect(ex[:class]).to eq("RuntimeError")
      expect(ex[:handled]).to be(false)
      expect(ex[:source]).to eq("application.action_cable")
      expect(JSON.parse(ex[:context])).to include("channel" => "WidgetChannel", "action" => "explode")
      expect(lantern_records(:broadcast).find { |r| r[:kind] == "perform_action" }[:failed]).to be(true)
      expect(parent).to include(status: "failed", failed: true, exception_preview: "RuntimeError: channel action failed")
      expect(ex[:execution_id]).to eq(parent[:execution_id])
      expect(Lantern.execution).to be_nil
    end
  end
end
