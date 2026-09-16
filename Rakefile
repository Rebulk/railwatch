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

  desc "Build the release .gem into pkg/ (dashboard bundle first)"
  task build: "dashboard:build" do
    mkdir_p "pkg"
    sh "gem build railwatch.gemspec --strict --output pkg/railwatch-#{Railwatch::VERSION}.gem"
  end
end
