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

  it "installs Lantern::Patches::RunnerCommand from the engine's runner hook, which bin/rails runner fires after boot" do
    # Not at boot: requiring railties' runner command in every web and
    # worker process cost boot time for a class those processes never call.
    Rails.application.load_runner
    require "rails/command"
    require "rails/commands/runner/runner_command"
    expect(Rails::Command::RunnerCommand.ancestors).to include(Lantern::Patches::RunnerCommand)
  end

  it "installs Lantern::Patches::RakeTask from the engine's rake_tasks hook, which a rake process fires after boot" do
    # spec_helper ran Rails.application.load_tasks once for the suite (Rake
    # appends actions, so loading twice would run every task twice).
    expect(Rake::Task.ancestors).to include(Lantern::Patches::RakeTask)
  end

  it "installs the rake and runner patches even when Lantern is not yet enabled at hook time" do
    # A rake process runs load_tasks from the Rakefile before initialize!,
    # so a token set in config/initializers/lantern.rb is not visible when
    # the rake_tasks hook fires. The hook must not gate on Lantern.enabled?;
    # the patches gate themselves on every call and are inert when off.
    allow(Lantern).to receive(:enabled?).and_return(false)
    rake_hooks = Lantern::Engine.instance_variable_get(:@rake_tasks) || Lantern::Engine.rake_tasks
    runner_hooks = Lantern::Engine.instance_variable_get(:@runner) || Lantern::Engine.runner
    expect(Lantern::Patches).to receive(:install_rake_task!).and_call_original
    expect(Lantern::Patches).to receive(:install_runner_command!).and_call_original
    rake_hooks.each { |blk| Lantern::Engine.instance.instance_exec(Rails.application, &blk) }
    runner_hooks.each { |blk| Lantern::Engine.instance.instance_exec(Rails.application, &blk) }
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

    # Inline code is typed by a human, so the record is marked interactive and
    # the exception is not reported -- see spec/lantern/patches/runner_command_spec.rb
    # for the four shapes and the deployed script that still reports.
    it "reports exit_code 1 and marks a typed one-liner interactive when the evaluated code raises" do
      expect { Rails::Command::RunnerCommand.new([]).perform("raise 'kaboom_runner'") }.to raise_error("kaboom_runner")

      cmd = lantern_records(:command).sole
      expect(cmd[:exit_code]).to eq(1)
      expect(cmd[:interactive]).to be(true)
      expect(lantern_records(:exception)).to be_empty
    end
  end
end
