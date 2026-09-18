# frozen_string_literal: true

require "spec_helper"
require "English"

# Bundler rewrites Gemfile.lock on the spot whenever resolution changes, and
# it does so before the process it was asked to run even starts: `bundle exec`
# on a lockfile saying 0.1.9 silently restores 0.2.0 and carries on. CI
# installs with `frozen`, which refuses to rewrite anything and fails the
# whole setup step before a single test runs.
#
# So the working tree always looks fine and the committed file is what breaks,
# which is why this has cost three red runs: two gems entered CHECKSUMS with
# no sha256 when the dashboard picked up tdigest, and the 0.2.0 bump restated
# the gem's own version. Both times the local lockfile was correct and
# uncommitted.
#
# These read the COMMITTED lockfile, because that is the one CI installs from.
# Failing here means "commit Gemfile.lock alongside the change you just made".
RSpec.describe "the committed Gemfile.lock" do
  def committed_lockfile
    @committed_lockfile ||= begin
      out = `git -C #{Rails.root.join('../..').expand_path} show HEAD:Gemfile.lock 2>/dev/null`
      $CHILD_STATUS.success? && !out.empty? ? out : nil
    end
  end

  # The gem itself is a path source: Bundler does not checksum what it has not
  # fetched, so this one entry is expected to carry none.
  def path_sourced = "railwatch"

  # Deliberately not `skip`: these exist to catch a mistake that only shows
  # up in CI, and a guard that quietly stands down is worse than none.
  it "can read the committed lockfile at all" do
    expect(committed_lockfile).to be_a(String).and(include("railwatch"))
  end

  it "records the version this gem currently declares" do
    locked = committed_lockfile[/^    railwatch \((?<version>[^)]+)\)$/, "version"]

    expect(locked).to eq(Railwatch::VERSION),
                      "The committed Gemfile.lock says railwatch #{locked.inspect} but lib/railwatch/version.rb " \
                      "says #{Railwatch::VERSION.inspect}. Bundler already fixed your working copy, which is why " \
                      "everything passes locally; CI installs frozen and fails before any test runs. Commit " \
                      "Gemfile.lock in the same commit as the version change."
  end

  it "carries a checksum for every gem it resolved" do
    section = committed_lockfile[/^CHECKSUMS$(?<body>.*?)^$/m, "body"].to_s
    entries = section.lines.filter_map { |line| line.match(/^  (?<name>\S+) \((?<version>[^)]+)\)(?<sha>.*)$/) }
    missing = entries.reject { |e| e[:name] == path_sourced || e[:sha].include?("sha256=") }
                     .map { |e| "#{e[:name]} #{e[:version]}" }

    expect(entries).not_to be_empty, "no CHECKSUMS section in the committed lockfile; its shape changed"
    expect(missing).to be_empty,
                       "these gems are in CHECKSUMS with no sha256: #{missing.join(', ')}. Bundler leaves the " \
                       "entry blank when it resolves a gem it did not download, and a frozen install refuses to " \
                       "fill it in. Fix with `bundle lock --add-checksums` and commit the result."
  end

  it "lists the runtime dependencies the gemspec declares" do
    locked = committed_lockfile[/^    railwatch \([^)]+\)\n(?<deps>(?:      .*\n)*)/, "deps"].to_s
                               .lines.filter_map { |line| line[/^      (\S+)/, 1] }.sort
    declared = Railwatch::Packaging.specification.dependencies.map(&:name).sort

    expect(locked).to eq(declared),
                      "The committed Gemfile.lock lists #{locked.inspect} under railwatch but the gemspec " \
                      "declares #{declared.inspect}. Run `bundle install` and commit Gemfile.lock."
  end
end
