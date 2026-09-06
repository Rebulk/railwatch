# frozen_string_literal: true

require "spec_helper"

RSpec.describe "deprecation record" do
  it "captures message, gem_name, and horizon for a notify-behavior deprecation warning" do
    deprecator = ActiveSupport::Deprecation.new("2.0", "Rails")
    deprecator.behavior = :notify

    Nightrail.start_execution(source: :command, sample_kind: :commands)
    deprecator.warn("old_method is deprecated")
    Nightrail.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)

    dep = nightrail_records(:deprecation).sole
    expect(dep[:message]).to start_with("DEPRECATION WARNING: old_method is deprecated")
    expect(dep[:gem_name]).to eq("Rails")
    expect(dep[:horizon]).to eq("2.0")
  end

  context "via a request", type: :request do
    it "captures the app callsite as :source when the deprecated method is called from application code" do
      Nightrail.start_execution(source: :command, sample_kind: :commands)
      get "/deprecated" # WidgetsController#deprecated_action calls a private method that warns
      Nightrail.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)

      dep = nightrail_records(:deprecation).sole
      expect(dep[:source]).to eq("app/controllers/widgets_controller.rb:88:in 'WidgetsController#deprecated_action'")
    end
  end

  it "is not recorded when the deprecator's behavior is not :notify (e.g. the app default :stderr)" do
    deprecator = ActiveSupport::Deprecation.new("2.0", "Rails")
    deprecator.behavior = :stderr

    Nightrail.start_execution(source: :command, sample_kind: :commands)
    deprecator.warn("not notified")
    Nightrail.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)

    expect(nightrail_records(:deprecation)).to be_empty
  end
end
