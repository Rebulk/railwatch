# frozen_string_literal: true

require "bundler/setup"
require "rspec/core/rake_task"
require_relative "lib/railwatch/version"

RSpec::Core::RakeTask.new(:spec)

desc "Overhead and no-app-DB-writes gates"
task :bench do
  %w[bench/overhead.rb bench/no_db_writes.rb].each do |script|
    sh "bundle exec ruby #{script}"
  end
end

task default: :spec

# The dashboard the gem ships is built from app/frontend at release time.
# Node and pnpm are needed here and nowhere else; a host application only
# ever sees public/railwatch.
require "json"

namespace :dashboard do
  desc "Build the dashboard bundle into public/railwatch (needs Node 22 + pnpm)"
  task :build do
    sh "pnpm install --frozen-lockfile"
    sh "pnpm exec vite build"
  end
end

namespace :package do
  desc "Build, inspect, install, and boot the public gem"
  task verify: "dashboard:build" do
    sh "bundle exec ruby script/verify_package"
  end

  # `gem build` globs the file list, so a missing or half-built bundle
  # produces a gem that installs happily and serves a blank dashboard. Cheap
  # to check, and the only moment it can be caught is before the push.
  desc "Fail unless the compiled dashboard is present and non-trivial"
  task :assert_dashboard do
    manifest = File.expand_path("public/railwatch/manifest.json", __dir__)
    abort "No dashboard bundle at #{manifest}; run `rake dashboard:build` first." unless File.exist?(manifest)

    entries = JSON.parse(File.read(manifest))
    abort "The dashboard manifest at #{manifest} is empty." if entries.empty?
    assets = Dir[File.expand_path("public/railwatch/assets/*", __dir__)]
    abort "The dashboard manifest lists #{entries.size} entries but public/railwatch/assets is empty." if assets.empty?
    puts "Dashboard bundle present: #{entries.size} manifest entries, #{assets.size} asset files."
  end

  desc "Build the release .gem into pkg/ (dashboard bundle first)"
  task build: "dashboard:build" do
    mkdir_p "pkg"
    sh "gem build railwatch.gemspec --strict --output pkg/railwatch-#{Railwatch::VERSION}.gem"
  end
end
