# frozen_string_literal: true

require "spec_helper"

RSpec.describe "deprecation record" do
  it "captures message, gem_name, and horizon for a notify-behavior deprecation warning" do
    deprecator = ActiveSupport::Deprecation.new("2.0", "Rails")
    deprecator.behavior = :notify

    Lantern.start_execution(source: :command, sample_kind: :commands)
    deprecator.warn("old_method is deprecated")
    Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)

    dep = lantern_records(:deprecation).sole
    expect(dep[:message]).to start_with("DEPRECATION WARNING: old_method is deprecated")
    expect(dep[:gem_name]).to eq("Rails")
    expect(dep[:horizon]).to eq("2.0")
  end

  context "via a request", type: :request do
    it "captures the app callsite as :source when the deprecated method is called from application code" do
      Lantern.start_execution(source: :command, sample_kind: :commands)
      get "/deprecated" # WidgetsController#deprecated_action calls a private method that warns
      Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)

      dep = lantern_records(:deprecation).sole
      # Ruby 3.4 added the owner to backtrace labels and changed the opening
      # delimiter from a backtick to a quote. The app file, line, and method
      # are the stable information Lantern receives on every supported Ruby.
      expect(dep[:source]).to match(%r{\Aapp/controllers/widgets_controller\.rb:88:in [`'](?:WidgetsController#)?deprecated_action'\z})
    end
  end

  it "is not recorded when the deprecator's behavior is not :notify (e.g. the app default :stderr)" do
    deprecator = ActiveSupport::Deprecation.new("2.0", "Rails")
    deprecator.behavior = :stderr

    Lantern.start_execution(source: :command, sample_kind: :commands)
    deprecator.warn("not notified")
    Lantern.finish_execution(:command, group: "g", class: "Rake::Task", name: "demo", command: "rake demo", exit_code: 0)

    expect(lantern_records(:deprecation)).to be_empty
  end
end
