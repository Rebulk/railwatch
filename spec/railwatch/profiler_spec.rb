# frozen_string_literal: true

require "spec_helper"

RSpec.describe Railwatch::Profiler do
  after do
    Railwatch.config.profiler = nil
    Railwatch.config.profile_interval_us = 1_000
    described_class.reset!
  end

  # Burns wall time in a frame with a name of its own, so any profile taken
  # while it runs must contain it.
  def churn(milliseconds)
    deadline = Railwatch::Clock.monotonic + (milliseconds / 1000.0)
    n = 0
    n += 1 while Railwatch::Clock.monotonic < deadline
    n
  end

  # A StackProf results hash in StackProf's own :raw layout -- `depth`, that
  # many frame ids outermost-first, then the sample weight -- so `collapse`
  # can be driven with exactly the input the real gem produces.
  def stackprof_result(stacks, files: {})
    ids = {}
    raw = []
    stacks.each do |names, weight|
      names.each { |name| ids[name] ||= ids.size + 1 }
      raw << names.size
      raw.concat(names.map { |name| ids[name] })
      raw << weight
    end
    { frames: ids.to_h { |name, id| [ id, { name: name, file: files[name], line: 12 } ] },
      raw: raw, samples: stacks.sum(&:last) }
  end

  describe "backend selection" do
    it "prefers vernier when both gems are installed" do
      expect(described_class.backend).to eq(:vernier)
      expect(described_class.available?).to be(true)
    end

    it "uses the backend config.profiler pins, even though vernier is also installed" do
      Railwatch.config.profiler = :stackprof

      expect(described_class.backend).to eq(:stackprof)
    end

    it "accepts config.profiler as a string" do
      Railwatch.config.profiler = "stackprof"

      expect(described_class.backend).to eq(:stackprof)
    end

    it "has no backend when config.profiler names one that isn't installed" do
      Railwatch.config.profiler = :not_a_profiler

      expect(described_class.backend).to be_nil
      expect(described_class.available?).to be(false)
      expect(described_class.start).to be_nil
    end

    it "has no backend when neither gem can be required" do
      hide_const("::Vernier")
      hide_const("::StackProf")
      allow(described_class).to receive(:require).and_raise(LoadError)
      described_class.reset!

      expect(described_class.backend).to be_nil
      expect(described_class.available?).to be(false)
      expect(described_class.start).to be_nil
    end
  end

  describe "start/stop" do
    %i[vernier stackprof].each do |backend|
      context "with #{backend}" do
        before do
          Railwatch.config.profiler = backend
          Railwatch.config.profile_interval_us = 500
        end

        it "profiles a busy block and reports the backend, mode, and interval it used" do
          described_class.start
          churn(60)
          profile = described_class.stop

          expect(profile.profiler).to eq(backend)
          expect(profile.mode).to eq(:wall)
          expect(profile.interval).to eq(500)
          expect(profile.duration).to be >= 60_000
        end

        it "collapses the busy block's own frame and sums every count into samples" do
          described_class.start
          churn(60)
          profile = described_class.stop

          expect(profile.samples).to be_positive
          expect(profile.collapsed).to include("#churn (")
          expect(profile.collapsed.lines.sum { |line| line.split(" ").last.to_i }).to eq(profile.samples)
        end

        it "writes one `outermost;...;leaf count` line per unique stack, most sampled first" do
          described_class.start
          churn(60)
          profile = described_class.stop

          counts = profile.collapsed.lines.map { |line| line.split(" ").last.to_i }
          expect(counts).to eq(counts.sort.reverse)
          expect(profile.collapsed.lines).to all(match(/\A\S.*;.* \d+\n\z/))
          # Frames are outermost-first, so churn sits before the clock read
          # it calls, not after it.
          expect(profile.collapsed).to include("clock_gettime")
          frames = profile.collapsed.lines.find { |line| line.include?("clock_gettime") }.split(";")
          expect(frames.index { |f| f.include?("#churn (") })
            .to be < frames.index { |f| f.include?("clock_gettime") }
        end
      end
    end

    it "returns nil from stop when nothing is running" do
      expect(described_class.stop).to be_nil
    end

    it "profiles one execution at a time and counts the ones it skipped" do
      first = described_class.start

      expect(first).not_to be_nil
      expect(described_class.start).to be_nil
      expect(described_class.skipped).to eq(1)
      expect(described_class.stop).not_to be_nil
    end

    it "frees the process-global slot again once the first profile stops" do
      described_class.start
      described_class.stop

      expect(described_class.start).not_to be_nil
      expect(described_class.skipped).to be_zero
      described_class.stop
    end

    it "degrades to nil, and stays startable, when the backend raises on start" do
      allow(::Vernier).to receive(:start_profile).and_raise("no profiler for you")

      expect(described_class.start).to be_nil
      expect(described_class.stop).to be_nil

      allow(::Vernier).to receive(:start_profile).and_call_original
      expect(described_class.start).not_to be_nil
      described_class.stop
    end

    it "degrades to nil when the backend raises on stop" do
      described_class.start
      allow(::Vernier).to receive(:stop_profile).and_raise("gone")

      expect(described_class.stop).to be_nil

      # The stub, not Railwatch, is what left vernier collecting: put the real
      # method back and stop it, or the next example inherits a live profile.
      allow(::Vernier).to receive(:stop_profile).and_call_original
      ::Vernier.stop_profile
    end
  end

  describe ".restart_after_fork!" do
    it "clears a profile the parent was taking so the child can profile again" do
      described_class.instance_variable_set(:@running, :parent_profile)
      described_class.instance_variable_set(:@skipped, 7)

      described_class.restart_after_fork!

      expect(described_class.instance_variable_get(:@running)).to be_nil
      expect(described_class.skipped).to eq(0)
      expect(described_class.start(mode: :wall)).to be_a(described_class::Handle)
    ensure
      described_class.stop
    end

    it "does not block on a lock another parent thread was holding" do
      lock = described_class.instance_variable_get(:@lock)
      locked = Queue.new
      release = Queue.new
      holder = Thread.new { lock.synchronize { locked << true; release.pop } }
      locked.pop

      expect { Timeout.timeout(5) { described_class.restart_after_fork! } }.not_to raise_error
    ensure
      release << true
      holder&.join
    end

    it "runs in the child from the Process._fork hook, leaving no parent profile behind" do
      skip "fork not supported on this platform" unless Process.respond_to?(:fork)

      # Exercise our real fork hook with a parent Handle, without forking an
      # active native sampler: Vernier can deadlock in the child before this
      # block runs. Native profiling is covered by the start/stop examples.
      allow(described_class).to receive(:start_backend).and_return(true)
      allow(described_class).to receive(:stop_backend).and_return(nil)
      described_class.start(mode: :wall)
      parent_handle = described_class.instance_variable_get(:@running)
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        cleared = described_class.instance_variable_get(:@running).nil?
        restarted = described_class.start(mode: :wall).is_a?(described_class::Handle)
        writer.write(cleared && restarted ? "ok" : "no")
        writer.close
        exit!(0)
      end
      writer.close
      expect(IO.select([ reader ], nil, nil, 5)).not_to be_nil, "forked profiler did not respond within 5 seconds"
      result = reader.read_nonblock(2)
      Timeout.timeout(5) { Process.wait(pid) }
      reaped = true

      expect(result).to eq("ok")
      expect(described_class.instance_variable_get(:@running)).to equal(parent_handle)
    ensure
      reader&.close unless reader&.closed?
      writer&.close unless writer&.closed?
      if pid && !reaped
        begin
          Process.kill("KILL", pid)
        rescue Errno::ESRCH
          # The child may already have exited.
        end
        begin
          Process.wait(pid)
        rescue Errno::ECHILD
          # A completed wait already reaped it.
        end
      end
      described_class.stop
    end
  end

  describe ".collapse" do
    it "orders by count descending, breaking ties on the stack text" do
      result = stackprof_result([ [ %w[root b], 1 ], [ %w[root c], 5 ], [ %w[root a], 1 ] ])

      leaves = described_class.collapse(result).lines.map { |line| line.split(";").last[/\A\w+/] }
      expect(leaves).to eq(%w[c a b])
    end

    it "formats each frame as `Class#method (path:line)`" do
      result = stackprof_result([ [ [ "Widget#save" ], 3 ] ], files: { "Widget#save" => "#{Railwatch::Backtrace.app_root}app/models/widget.rb" })

      expect(described_class.collapse(result)).to eq("Widget#save (app/models/widget.rb:12) 3\n")
    end

    it "shortens an installed gem's path to gem/relative/path" do
      gem_file = "#{Gem.path.first}/gems/activerecord-8.1.0/lib/active_record/relation.rb"
      result = stackprof_result([ [ [ "ActiveRecord::Relation#load" ], 1 ] ], files: { "ActiveRecord::Relation#load" => gem_file })

      expect(described_class.collapse(result))
        .to eq("ActiveRecord::Relation#load (activerecord/lib/active_record/relation.rb:12) 1\n")
    end

    it "leaves a path that is neither the app nor an installed gem alone" do
      result = stackprof_result([ [ [ "Kernel#sleep" ], 1 ] ], files: { "Kernel#sleep" => "/opt/other/thing.rb" })

      expect(described_class.collapse(result)).to eq("Kernel#sleep (/opt/other/thing.rb:12) 1\n")
    end

    it "reports a frame with no Ruby file of its own as <cfunc>:0" do
      result = { frames: { 1 => { name: "Integer#+", file: "<cfunc>", line: nil } }, raw: [ 1, 1, 4 ] }

      expect(described_class.collapse(result)).to eq("Integer#+ (<cfunc>:0) 4\n")
    end

    it "shortens Ruby's own library path to ruby/relative/path" do
      result = stackprof_result([ [ [ "Kernel#sleep" ], 1 ] ], files: { "Kernel#sleep" => "#{RbConfig::CONFIG['rubylibdir']}/net/http.rb" })

      expect(described_class.collapse(result)).to eq("Kernel#sleep (ruby/net/http.rb:12) 1\n")
    end

    it "caps the text at 4 MiB, dropping the least frequent stacks" do
      stacks = 30_000.times.map { |i| [ [ "Big::Class#method_#{i}#{'x' * 200}" ], i + 1 ] }
      collapsed = described_class.collapse(stackprof_result(stacks))

      expect(collapsed.bytesize).to be <= Railwatch::Profiler::MAX_COLLAPSED_BYTES
      expect(collapsed).to include("method_29999")
      expect(collapsed).not_to include("method_0x")
    end

    it "folds only the thread that asked for the profile, not vernier's view of every thread" do
      Railwatch.config.profile_interval_us = 500
      idle = Thread.new { sleep 1 }
      described_class.start
      churn(60)
      profile = described_class.stop
      idle.kill

      expect(profile.collapsed).to include("#churn (")
      expect(profile.collapsed).not_to include("Kernel#sleep")
    end
  end
end
