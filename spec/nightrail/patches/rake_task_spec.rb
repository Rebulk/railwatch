# frozen_string_literal: true

require "spec_helper"
require "rake"

RSpec.describe Nightrail::Patches::RakeTask do
  it "ships a command record with class Rake::Task, the task name, the full rake invocation, and exit_code 0" do
    Rake::Task.define_task(:nightrail_spec_plain) { Widget.create!(name: "from_rake") }
    Rake::Task[:nightrail_spec_plain].execute

    cmd = nightrail_records(:command).sole
    expect(cmd[:class]).to eq("Rake::Task")
    expect(cmd[:name]).to eq("nightrail_spec_plain")
    expect(cmd[:command]).to eq("rake nightrail_spec_plain")
    expect(cmd[:exit_code]).to eq(0)
  end

  it "includes task arguments in the command string" do
    Rake::Task.define_task(:nightrail_spec_args, [ :a, :b ])
    Rake::Task[:nightrail_spec_args].execute(Rake::TaskArguments.new([ :a, :b ], [ "x", "y" ]))

    expect(nightrail_records(:command).sole[:command]).to eq("rake nightrail_spec_args[x,y]")
  end

  it "clamps a SystemExit status to the 0..255 exit_code range in both directions" do
    Rake::Task.define_task(:nightrail_spec_neg) { raise SystemExit.new(-5) }
    expect { Rake::Task[:nightrail_spec_neg].execute }.to raise_error(SystemExit)
    expect(nightrail_records(:command).sole[:exit_code]).to eq(0)

    nightrail_transport.batches.clear
    Rake::Task.define_task(:nightrail_spec_big) { raise SystemExit.new(300) }
    expect { Rake::Task[:nightrail_spec_big].execute }.to raise_error(SystemExit)
    expect(nightrail_records(:command).sole[:exit_code]).to eq(255)
  end

  # SIGTERM is how Kamal and systemd stop a long-running task (the platform's
  # own `litestream:replicate` role opened one issue per deploy this way).
  it "treats a shutdown signal as an exit, not an error: exit_code 128+signo and no exception record" do
    Rake::Task.define_task(:nightrail_spec_term) { raise SignalException, "SIGTERM" }
    expect { Rake::Task[:nightrail_spec_term].execute }.to raise_error(SignalException)

    cmd = nightrail_records(:command).sole
    expect(cmd[:exit_code]).to eq(128 + Signal.list["TERM"])
    expect(nightrail_records(:exception)).to be_empty
  end

  it "reports exit_code 1 and captures the exception for an unhandled StandardError" do
    Rake::Task.define_task(:nightrail_spec_boom) { raise "kaboom" }
    expect { Rake::Task[:nightrail_spec_boom].execute }.to raise_error("kaboom")

    expect(nightrail_records(:command).sole[:exit_code]).to eq(1)
    ex = nightrail_records(:exception).sole
    expect(ex[:message]).to eq("kaboom")
    expect(ex[:source]).to eq("application.rake")
  end

  it "never ships a command record for the environment task" do
    Rake::Task.define_task(:environment) unless Rake::Task.task_defined?(:environment)
    Rake::Task[:environment].execute

    expect(nightrail_records(:command)).to be_empty
  end

  it "skips a default vendor command like db:migrate unless capture_default_vendor_commands is enabled" do
    expect(Nightrail::Configuration::DEFAULT_VENDOR_COMMANDS).to include("db:migrate")
    Rake::Task.define_task("db:migrate") unless Rake::Task.task_defined?("db:migrate")
    Rake::Task["db:migrate"].execute
    expect(nightrail_records(:command)).to be_empty

    Nightrail.config.capture_default_vendor_commands = true
    Rake::Task["db:migrate"].execute
    expect(nightrail_records(:command).sole[:name]).to eq("db:migrate")
  ensure
    Nightrail.config.capture_default_vendor_commands = false
  end

  it "ships one command record per task instead of nesting a prerequisite inside its dependent's execution" do
    Rake::Task.define_task(:nightrail_spec_child) { Rails.logger.info("child") }
    Rake::Task.define_task(nightrail_spec_parent: :nightrail_spec_child) { Rails.logger.info("parent") }

    Rake::Task[:nightrail_spec_parent].invoke

    expect(nightrail_records(:command).size).to eq(1)
  end
end
