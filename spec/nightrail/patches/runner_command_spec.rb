# frozen_string_literal: true

require "spec_helper"
require "rails/command"
require "rails/commands/runner/runner_command"

RSpec.describe Nightrail::Patches::RunnerCommand do
  # Prepended from the engine's runner hook, which only a real
  # `bin/rails runner` process fires, so make sure of it here.
  before(:context) do
    Rails::Command::RunnerCommand.prepend(described_class) unless
      Rails::Command::RunnerCommand.ancestors.include?(described_class)
  end

  # railties sets $0 to the script it loads, and replaces ARGV; neither
  # belongs to this suite.
  around do |example|
    program, argv = $PROGRAM_NAME, ARGV.dup
    example.run
  ensure
    $PROGRAM_NAME = program
    ARGV.replace(argv)
  end

  def run_runner(*args)
    Rails::Command::RunnerCommand.new([]).perform(*args)
  end

  def write_script(path, body)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, body)
    @scripts = (@scripts || []) << path
    path
  end

  after { @scripts&.each { |path| FileUtils.rm_f(path) } }

  # 1. `rails runner -`: an engineer piping a heredoc into production.
  describe "piped stdin" do
    it "ships an interactive command record and opens no issue" do
      original = $stdin
      $stdin = StringIO.new("raise 'typed_into_stdin'")
      expect { run_runner("-") }.to raise_error("typed_into_stdin")

      cmd = nightrail_records(:command).sole
      expect(cmd[:interactive]).to be(true)
      expect(cmd[:exit_code]).to eq(1)
      expect(cmd[:command]).to eq("rails runner -")
      expect(nightrail_records(:exception)).to be_empty
    ensure
      $stdin = original
    end
  end

  # 2. `rails runner 'Org.find_by(slug: "nope").destroy!'`: the typo that
  #    opened REBULK-CLOUD-M.
  describe "inline code" do
    it "ships an interactive command record and opens no issue" do
      expect { run_runner("raise 'typed_at_the_shell'") }.to raise_error("typed_at_the_shell")

      cmd = nightrail_records(:command).sole
      expect(cmd[:interactive]).to be(true)
      expect(cmd[:exit_code]).to eq(1)
      expect(nightrail_records(:exception)).to be_empty
    end

    # REBULK-CLOUD-M exactly: railties rescues the NameError from its own
    # eval and exits 1, but the Rails executor has already handed the error
    # to Rails.error by then, so this only stays out of the issue stream
    # because the execution is flagged interactive.
    it "opens no issue for a NameError typo, which railties turns into exit 1" do
      original = $stderr
      $stderr = StringIO.new
      expect { run_runner("Widget.find_by(name: 'nope').destroy!") }.to raise_error(SystemExit)

      expect(nightrail_records(:command).sole[:exit_code]).to eq(1)
      expect(nightrail_records(:exception)).to be_empty
    ensure
      $stderr = original
    end

    it "still records the run itself, with the code preview and its exception preview" do
      run_runner("Widget.create!(name: 'via_runner')")

      cmd = nightrail_records(:command).sole
      expect(cmd[:command]).to eq("rails runner Widget.create!(name: 'via_runner')")
      expect(cmd[:exit_code]).to eq(0)
      expect(Widget.exists?(name: "via_runner")).to be(true)
    end
  end

  # 3. `rails runner /tmp/probe.rb`: a probe written into a running container,
  #    which is REBULK-CLOUD-11. A file, but nothing an app deploys lives there.
  describe "a script in a scratch directory" do
    it "ships an interactive command record and opens no issue" do
      script = write_script("/tmp/nightrail_runner_spec_probe.rb", "raise 'probe_in_tmp'")
      expect { run_runner(script) }.to raise_error("probe_in_tmp")

      expect(nightrail_records(:command).sole[:interactive]).to be(true)
      expect(nightrail_records(:exception)).to be_empty
    end

    it "treats a scratch directory as deployed once it is off interactive_runner_paths" do
      Nightrail.config.interactive_runner_paths = [ "/var/tmp/" ]
      script = write_script("/tmp/nightrail_runner_spec_probe2.rb", "raise 'probe_in_tmp'")
      expect { run_runner(script) }.to raise_error("probe_in_tmp")

      expect(nightrail_records(:command).sole[:interactive]).to be_nil
      expect(nightrail_records(:exception).sole[:message]).to eq("probe_in_tmp")
    ensure
      Nightrail.config.interactive_runner_paths = Nightrail::Configuration::DEFAULT_INTERACTIVE_RUNNER_PATHS.dup
    end
  end

  # 4. `rails runner script/nightly.rb`: the deployed, scheduled script. This
  #    is the case the whole filter must never silence.
  describe "a deployed script" do
    it "reports the exception, with no interactive flag on the command record" do
      script = write_script(Rails.root.join("script/nightrail_runner_spec_nightly.rb").to_s, "raise 'nightly_is_broken'")
      expect { run_runner(script) }.to raise_error("nightly_is_broken")

      cmd = nightrail_records(:command).sole
      expect(cmd[:interactive]).to be_nil
      expect(cmd[:exit_code]).to eq(1)
      expect(nightrail_records(:exception).sole[:message]).to eq("nightly_is_broken")
    end
  end

  describe ".interactive?" do
    it "classifies by where the code came from, not by what it does" do
      expect(described_class.interactive?("-")).to be(true)
      expect(described_class.interactive?(nil)).to be(true)
      expect(described_class.interactive?("Widget.count")).to be(true)
      expect(described_class.interactive?("/tmp/probe.rb")).to be(true)
      expect(described_class.interactive?("/var/tmp/probe.rb")).to be(true)
      expect(described_class.interactive?("script/nightly.rb")).to be(false)
      expect(described_class.interactive?("/opt/app/script/nightly.rb")).to be(false)
      expect(described_class.interactive?(Rails.root.join("script/nightly.rb").to_s)).to be(false)
    end

    # A relative path is judged by where it resolves, so `runner ../../tmp/x.rb`
    # cannot dodge the rule (or trip it) on spelling alone.
    it "expands a relative path before matching a scratch directory" do
      Dir.chdir("/tmp") do
        expect(described_class.interactive?("probe.rb")).to be(true)
      end
    end
  end

  # In a real `bin/rails runner` process the prepend happens inside
  # boot_application!, i.e. inside the #perform already on the stack, so the
  # #perform override is never what runs. conditional_executor, called by
  # that same #perform after boot, is -- and it has to classify from Thor's
  # parsed args since nothing hands it code_or_file.
  describe "when the patch lands mid-perform (a real shell invocation)" do
    def run_unpatched_perform(*argv)
      command = Rails::Command::RunnerCommand.new(argv)
      command.send(:conditional_executor, true, source: "application.runner.railties") { yield }
    end

    it "still opens the execution, and withholds the exception of a script under /tmp" do
      path = write_script("/tmp/nightrail_probe_#{Process.pid}.rb", "")
      expect { run_unpatched_perform(path) { raise "typed_from_a_shell" } }.to raise_error("typed_from_a_shell")

      cmd = nightrail_records(:command).sole
      expect(cmd).to include(interactive: true, exit_code: 1, command: "rails runner #{path}")
      expect(nightrail_records(:exception)).to be_empty
      expect(Nightrail.execution).to be_nil
    end

    it "still reports the exception of a deployed script" do
      path = write_script(File.join(Dir.pwd, "script", "nightrail_probe_#{Process.pid}.rb"), "")
      expect { run_unpatched_perform(path, "arg1") { raise "nightly_died" } }.to raise_error("nightly_died")

      expect(nightrail_records(:command).sole).not_to include(:interactive)
      expect(nightrail_records(:exception).sole).to include(message: "nightly_died")
    end

    it "does not open a second execution when the patched #perform is already on the stack" do
      expect { run_runner("raise 'once'") }.to raise_error("once")
      expect(nightrail_records(:command).size).to eq(1)
    end
  end
end
