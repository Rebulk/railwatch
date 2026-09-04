# frozen_string_literal: true

require "bundler/setup"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

desc "Overhead and no-app-DB-writes gates"
task :bench do
  %w[bench/overhead.rb bench/no_db_writes.rb].each do |script|
    sh "bundle exec ruby #{script}"
  end
end

task default: :spec

namespace :package do
  desc "Build, inspect, install, and boot the public gem and legacy Git package"
  task :verify do
    sh "bundle exec ruby script/verify_package"
  end
end
