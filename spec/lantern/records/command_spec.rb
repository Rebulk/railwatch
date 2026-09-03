# frozen_string_literal: true

require "spec_helper"
require "rake"

RSpec.describe "command record" do
  it "captures class Rake::Task, name, the rake invocation string with args, and exit_code for a rake task" do
    Rake::Task.define_task(:lantern_cmd_spec, [ :a ]) { |_, args| Widget.create!(name: args[:a]) }
    Rake::Task[:lantern_cmd_spec].execute(Rake::TaskArguments.new([ :a ], [ "from_rake" ]))

    cmd = lantern_records(:command).sole
    expect(cmd[:class]).to eq("Rake::Task")
    expect(cmd[:name]).to eq("lantern_cmd_spec")
    expect(cmd[:command]).to eq("rake lantern_cmd_spec[from_rake]")
    expect(cmd[:exit_code]).to eq(0)
    expect(Widget.exists?(name: "from_rake")).to be(true)
  end

  it "installs Lantern::Patches::RunnerCommand on Rails::Command::RunnerCommand at boot" do
    require "rails/command"
    require "rails/commands/runner/runner_command"
    expect(Rails::Command::RunnerCommand.ancestors).to include(Lantern::Patches::RunnerCommand)
  end

  context "once Rails::Command::RunnerCommand is actually prepended (simulating the require path being fixed)" do
    before(:context) do
      require "rails/command"
      require "rails/commands/runner/runner_command"
      Rails::Command::RunnerCommand.prepend(Lantern::Patches::RunnerCommand) unless
        Rails::Command::RunnerCommand.ancestors.include?(Lantern::Patches::RunnerCommand)
    end

    it "captures class, name, command with the code preview, and exit_code 0 for a clean run" do
      Rails::Command::RunnerCommand.new([]).perform("Widget.create!(name: 'via_runner')")

      cmd = lantern_records(:command).sole
      expect(cmd[:class]).to eq("Rails::Command::RunnerCommand")
      expect(cmd[:name]).to eq("runner")
      expect(cmd[:command]).to eq("rails runner Widget.create!(name: 'via_runner')")
      expect(cmd[:exit_code]).to eq(0)
    end

    it "reports exit_code 1 and captures the exception when the evaluated code raises" do
      expect { Rails::Command::RunnerCommand.new([]).perform("raise 'kaboom_runner'") }.to raise_error("kaboom_runner")

      expect(lantern_records(:command).sole[:exit_code]).to eq(1)
      expect(lantern_records(:exception).sole[:message]).to eq("kaboom_runner")
    end
  end
end
