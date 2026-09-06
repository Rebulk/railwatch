# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Nightrail::Patches::Inertia" do
  it "is already prepended onto InertiaRails::Renderer at boot, since inertia_rails is loaded in this dummy app" do
    expect(InertiaRails::Renderer.ancestors).to include(Nightrail::Patches::Inertia::Renderer)
  end

  it "install! is a no-op (does not raise or double-prepend) when called again" do
    expect { Nightrail::Patches::Inertia.install! }.not_to raise_error
    expect(InertiaRails::Renderer.ancestors.count(Nightrail::Patches::Inertia::Renderer)).to eq(1)
  end

  # InertiaRails::Renderer#initialize requires a real controller/request/response,
  # so the module is exercised directly on a bare double the same way
  # records/command_spec.rb isolates Patches::RunnerCommand's wrapping logic
  # from Rails::Command::RunnerCommand's own construction.
  describe "the prepended Renderer behavior" do
    let(:env) { {} }
    let(:fake_request) { Struct.new(:env).new(env) }
    let(:host) do
      Class.new do
        def initialize(request, component)
          @request = request
          @component = component
        end

        def render = "rendered"
        def ssr_render = "ssr rendered"
      end.tap { |klass| klass.prepend(Nightrail::Patches::Inertia::Renderer) }
    end

    it "stamps the request env with the component name on #render, then calls super" do
      result = host.new(fake_request, "widgets/index").render

      expect(result).to eq("rendered")
      expect(env["nightrail.inertia_component"]).to eq("widgets/index")
    end

    it "stamps the request env with elapsed milliseconds on #ssr_render, then calls super" do
      result = host.new(fake_request, "widgets/index").ssr_render

      expect(result).to eq("ssr rendered")
      expect(env["nightrail.inertia_ssr_ms"]).to be_a(Float).and be >= 0
    end

    it "does not raise when the renderer has no @request (env is nil)" do
      no_request_host = Class.new do
        def initialize(component) = @component = component
        def render = "rendered"
      end.tap { |klass| klass.prepend(Nightrail::Patches::Inertia::Renderer) }

      expect(no_request_host.new("widgets/index").render).to eq("rendered")
    end
  end
end
