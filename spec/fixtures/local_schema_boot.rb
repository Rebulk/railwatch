# frozen_string_literal: true

require "bundler/setup"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "railwatch"

module RailwatchSchemaBoot
  class Application < Rails::Application
    config.load_defaults 8.1
    config.root = ENV.fetch("RAILWATCH_SCHEMA_BOOT_ROOT")
    config.eager_load = true
    config.secret_key_base = "railwatch-schema-boot-test"
    config.logger = Logger.new(IO::NULL)
    config.cache_store = :memory_store
    config.hosts.clear
    config.active_record.migration_error = :page_load
    config.action_dispatch.show_exceptions = :none
    config.active_record.check_schema_cache_dump_version = false
  end
end

Rails.application.initialize!
Rails.application.routes.draw do
  mount Railwatch::Engine, at: "/railwatch"
  get "/sample", to: "rails/health#show"
end

request = Rack::MockRequest.new(Rails.application)
response = request.get("/sample")
abort "host route failed before Railwatch migrations: #{response.status}: #{response.body}" unless response.status == 200
response = request.get("/railwatch/apps/1/envs/1/requests")
abort "dashboard did not authenticate first" unless response.status == 401 && !response.body.include?("db:migrate")
response = request.get("/railwatch/apps/1/envs/1/requests",
  "HTTP_AUTHORIZATION" => "Basic #{Base64.strict_encode64('operator:schema-password')}")
guidance = ENV["RAILWATCH_SCHEMA_BOOT_UNCONFIGURED"] ? "railwatch:install --local" : "db:migrate:railwatch_telemetry"
abort "dashboard did not explain schema repair" unless response.status == 503 && response.body.include?(guidance)
response = request.post("/railwatch/beacon", "CONTENT_TYPE" => "application/json",
  input: JSON.generate(visits: [ { component: "RailwatchSchemaBoot", duration_ms: 1 } ]))
abort "beacon failed while Railwatch migrations were pending" unless response.status == 204

if ENV["RAILWATCH_SCHEMA_BOOT_UNCONFIGURED"]
  puts "RAILWATCH_SCHEMA_UNCONFIGURED_BOOT_OK"
  exit
end

ActiveRecord::Migration.verbose = false
%w[railwatch railwatch_telemetry].each do |name|
  config = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env, name: name)
  ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(config) { |connection| connection.pool.migration_context.migrate }
end

abort "schema did not recover after real migrations" unless Railwatch::RuntimeSchema.status(force: true).ready?
abort "host route failed after Railwatch migrations" unless request.get("/sample").status == 200
Railwatch.flush
Railwatch.reporter.shutdown
abort "capture did not resume" unless Railwatch::Telemetry::Execution.where(kind: "request").exists?
abort "host database contains Railwatch tables" if ActiveRecord::Base.connection.tables.any? { |table| table.start_with?("railwatch_") || table == "executions" }
puts "RAILWATCH_SCHEMA_BOOT_AND_RECOVERY_OK"
