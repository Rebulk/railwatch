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

namespace :package do
  desc "Build, inspect, install, and boot the public gem"
  task :verify do
    sh "bundle exec ruby script/verify_package"
  end

  desc "Build the release .gem into pkg/"
  task :build do
    mkdir_p "pkg"
    sh "gem build railwatch.gemspec --strict --output pkg/railwatch-#{Railwatch::VERSION}.gem"
  end
end
