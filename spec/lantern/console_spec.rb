# frozen_string_literal: true

require "spec_helper"

RSpec.describe Lantern::Console do
  # Rails::Console is not defined in this suite (railties only defines it when
  # it loads the console command), so a console is simulated by defining it,
  # exactly as `bin/rails console` has already done by the time Lantern's
  # initializers run. Quiet mode is process-wide, so every example puts the
  # config back.
  after do
    Lantern.config.enabled = true
    Lantern.config.capture_console = false
  end

  it "leaves a server process alone" do
    expect(described_class.detected?).to be(false)
    expect(described_class.quiet?).to be(false)
    expect(described_class.silence!).to be(false)
    expect(Lantern.enabled?).to be(true)
  end

  context "in a console process" do
    before { stub_const("Rails::Console", Class.new) }

    it "goes quiet, and reports having done so only once" do
      expect(described_class.detected?).to be(true)
      expect(described_class.quiet?).to be(true)
      expect(described_class.silence!).to be(true)
      expect(Lantern.enabled?).to be(false)
      expect(described_class.silence!).to be(false)
    end

    # The whole point: a typo at the prompt opened four production issues
    # under Sentry's successor wiring. An exception is a standalone record,
    # so with capture on this ships even with nothing executing.
    it "opens no issue for an exception raised at the prompt" do
      described_class.silence!
      Lantern.report(NoMethodError.new("undefined method 'destroy!' for nil"), handled: false)

      expect(lantern_records(:exception)).to be_empty
    end

    it "sends no process record, because a console is not a server" do
      described_class.silence!
      Lantern::Subscribers::ProcessInfo.install!(Rails.application)
      Lantern::Subscribers::ProcessInfo.record!

      expect(lantern_records(:process)).to be_empty
    end

    # Nothing is written, so the reporter never arms its flusher thread --
    # and the engine's health/sessions initializers skip for the same reason
    # (`next unless Lantern.enabled?`).
    it "leaves no background thread running behind the prompt" do
      described_class.silence!
      Lantern.record(:process, pid: Process.pid, role: "console")

      expect(Lantern.reporter.instance_variable_get(:@thread)).to be_nil
    end

    it "captures everything as usual when capture_console is on" do
      Lantern.config.capture_console = true

      expect(described_class.detected?).to be(true)
      expect(described_class.quiet?).to be(false)
      expect(described_class.silence!).to be(false)
      expect(Lantern.enabled?).to be(true)
    end
  end

  # The engine's `console` railtie block, for a console that reaches a prompt
  # without railties having defined Rails::Console before boot.
  it "is called from the engine's console railtie block" do
    blocks = Lantern::Engine.console # the registered blocks, when called without one
    expect(blocks).not_to be_empty

    stub_const("Rails::Console", Class.new)
    blocks.each { |block| block.call(Rails.application) }

    expect(Lantern.enabled?).to be(false)
  end
end
