# frozen_string_literal: true

# `bin/rails db:prepare` as a container entrypoint runs it: a fresh process,
# Rails' own database tasks loaded through load_tasks (which is also where
# the engine installs its patches), Railwatch switched off, and the app's
# databases declared the way the installer writes them. The caller holds the
# telemetry database's write lock from another process while this runs.
require "bundler/setup"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "rake"
require "railwatch"

class DbPrepareBootApplication < Rails::Application
  config.load_defaults 8.1
  config.root = ENV.fetch("DB_PREPARE_BOOT_ROOT")
  config.eager_load = false
  config.secret_key_base = "db-prepare-boot-test"
  config.logger = Logger.new(IO::NULL)
  config.cache_store = :memory_store
  config.hosts.clear
  config.active_record.dump_schema_after_migration = false
end

Rails.application.load_tasks
# What a real app's config/environment.rb does when db:prepare's
# :environment prerequisite requires it.
Rake::Task.define_task(:environment) { Rails.application.initialize! }
ENV["VERBOSE"] = "false"
Rake::Task["db:prepare"].invoke
puts "DB_PREPARE_OK"
