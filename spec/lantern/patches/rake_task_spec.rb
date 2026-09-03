# frozen_string_literal: true

require "spec_helper"
require "rake"

RSpec.describe Lantern::Patches::RakeTask do
  it "ships a command record with class Rake::Task, the task name, the full rake invocation, and exit_code 0" do
    Rake::Task.define_task(:lantern_spec_plain) { Widget.create!(name: "from_rake") }
    Rake::Task[:lantern_spec_plain].execute

    cmd = lantern_records(:command).sole
    expect(cmd[:class]).to eq("Rake::Task")
    expect(cmd[:name]).to eq("lantern_spec_plain")
    expect(cmd[:command]).to eq("rake lantern_spec_plain")
    expect(cmd[:exit_code]).to eq(0)
  end

  it "includes task arguments in the command string" do
    Rake::Task.define_task(:lantern_spec_args, [ :a, :b ])
    Rake::Task[:lantern_spec_args].execute(Rake::TaskArguments.new([ :a, :b ], [ "x", "y" ]))

    expect(lantern_records(:command).sole[:command]).to eq("rake lantern_spec_args[x,y]")
  end

  it "clamps a SystemExit status to the 0..255 exit_code range in both directions" do
    Rake::Task.define_task(:lantern_spec_neg) { raise SystemExit.new(-5) }
    expect { Rake::Task[:lantern_spec_neg].execute }.to raise_error(SystemExit)
    expect(lantern_records(:command).sole[:exit_code]).to eq(0)

    lantern_transport.batches.clear
    Rake::Task.define_task(:lantern_spec_big) { raise SystemExit.new(300) }
    expect { Rake::Task[:lantern_spec_big].execute }.to raise_error(SystemExit)
    expect(lantern_records(:command).sole[:exit_code]).to eq(255)
  end

  it "reports exit_code 1 and captures the exception for an unhandled StandardError" do
    Rake::Task.define_task(:lantern_spec_boom) { raise "kaboom" }
    expect { Rake::Task[:lantern_spec_boom].execute }.to raise_error("kaboom")

    expect(lantern_records(:command).sole[:exit_code]).to eq(1)
    ex = lantern_records(:exception).sole
    expect(ex[:message]).to eq("kaboom")
    expect(ex[:source]).to eq("application.rake")
  end

  it "never ships a command record for the environment task" do
    Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)
    Rake::Task[:environment].execute

    expect(lantern_records(:command)).to be_empty
  end

  it "skips a default vendor command like db:migrate unless capture_default_vendor_commands is enabled" do
    expect(Lantern::Configuration::DEFAULT_VENDOR_COMMANDS).to include("db:migrate")
    Rake::Task.define_task("db:migrate") unless Rake::Task.task_defined?("db:migrate")
    Rake::Task["db:migrate"].execute
    expect(lantern_records(:command)).to be_empty

    Lantern.config.capture_default_vendor_commands = true
    Rake::Task["db:migrate"].execute
    expect(lantern_records(:command).sole[:name]).to eq("db:migrate")
  ensure
    Lantern.config.capture_default_vendor_commands = false
  end

  it "ships one command record per task instead of nesting a prerequisite inside its dependent's execution" do
    pending "bug: Lantern::Patches::RakeTask's own comment says \"nested tasks (prerequisites) run " \
            "inside\" the top-level task's command execution, guarded by `Lantern.execution.nil?` in " \
            "#execute. But Rake::Task#invoke_with_call_chain calls invoke_prerequisites (which fully " \
            "invokes AND executes each prerequisite, finishing its own Lantern execution via the " \
            "`ensure` block) BEFORE calling the dependent task's own #execute -- so by the time the " \
            "parent's #execute runs, Lantern.execution is nil again and it starts a second, unrelated " \
            "top-level command execution. Only #execute is patched; prerequisites are dispatched via " \
            "#invoke, which Lantern never intercepts, so nesting never actually happens."
    Rake::Task.define_task(:lantern_spec_child) { Rails.logger.info("child") }
    Rake::Task.define_task(lantern_spec_parent: :lantern_spec_child) { Rails.logger.info("parent") }

    Rake::Task[:lantern_spec_parent].invoke

    expect(lantern_records(:command).size).to eq(1)
  end
end
