# frozen_string_literal: true

# A fresh process is essential: the regular dummy app has both Railwatch
# databases and has already loaded its models before any example runs.
require "bundler/setup"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_cable/engine"
require "solid_queue" if ENV.fetch("SOLID_QUEUE") == "true"
require "webmock"
require "railwatch"

WebMock.enable!
WebMock.disable_net_connect!
records = []
WebMock.stub_request(:post, "http://127.0.0.1:19473/ingest").to_return do |request|
  batch = Zlib::GzipReader.new(StringIO.new(request.body)).each_line.map { |line| JSON.parse(line) }
  records.concat(batch)
  { status: 200, body: JSON.generate(accepted: batch.size, rejected: 0) }
end

class CloudBootApplication < Rails::Application
  config.load_defaults 8.1
  config.root = ENV.fetch("CLOUD_BOOT_ROOT")
  config.eager_load = true
  config.secret_key_base = "cloud-boot-test"
  config.logger = Logger.new(IO::NULL)
  config.cache_store = :memory_store
  config.hosts.clear
  # activerecord-tenanted sets this false in real hosts, making Rails inspect
  # every loaded model's connection_pool when defining attribute methods.
  config.active_record.check_schema_cache_dump_version = ENV.fetch("CHECK_SCHEMA_CACHE") == "true"
end

Rails.application.initialize!
Rails.application.routes.draw do
  mount Railwatch::Engine, at: "/railwatch"
  get "/up", to: "rails/health#show"
end

response = Rack::MockRequest.new(Rails.application).get("/up")
abort "health check failed: #{response.status}" unless response.status == 200
response = Rack::MockRequest.new(Rails.application).post("/railwatch/beacon",
  "CONTENT_TYPE" => "application/json", input: JSON.generate(visits: [ { component: "CloudBoot", duration_ms: 12 } ]))
abort "beacon failed: #{response.status}" unless response.status == 204

Railwatch.report(RuntimeError.new("cloud boot regression"), handled: true)
Railwatch.flush
Railwatch.reporter.shutdown
abort "exception was not sent over HTTP" unless records.any? { |record| record["t"] == "exception" && record["message"] == "cloud boot regression" }
abort "beacon was not sent over HTTP" unless records.any? { |record| record["t"] == "visit" && record["component"] == "CloudBoot" }
abort "cloud mode loaded TelemetryRecord" if $LOADED_FEATURES.any? { |path| path.end_with?("/railwatch/telemetry_record.rb") }
abort "cloud mode loaded embedded database models" if ActiveRecord::Base.descendants.any? { |model| model.name&.start_with?("Railwatch::") }

puts "CLOUD_BOOT_AND_REPORT_OK"
