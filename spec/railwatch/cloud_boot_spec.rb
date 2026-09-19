# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

RSpec.describe "a cloud-only production boot" do
  [ [ true, false ], [ false, false ], [ false, true ] ].each do |check_schema_cache, solid_queue|
    it "boots and reports without telemetry models (schema version check: #{check_schema_cache}, Solid Queue: #{solid_queue})" do
      Dir.mktmpdir("railwatch-cloud-boot") do |root|
        FileUtils.mkdir_p("#{root}/config/initializers")
        FileUtils.mkdir_p("#{root}/app/controllers")
        File.write("#{root}/app/controllers/application_controller.rb", "class ApplicationController < ActionController::Base; end\n")
        File.write("#{root}/config/database.yml", "production:\n  adapter: sqlite3\n  database: ':memory:'\n")
        File.write("#{root}/config/initializers/railwatch.rb", <<~RUBY)
          Railwatch.configure do |config|
            config.transport = :http
            config.token = "cloud-boot-token"
            config.ingest_url = "http://127.0.0.1:19473"
          end
        RUBY

        output, status = Open3.capture2e(
          { "RAILS_ENV" => "production", "CLOUD_BOOT_ROOT" => root,
            "CHECK_SCHEMA_CACHE" => check_schema_cache.to_s, "SOLID_QUEUE" => solid_queue.to_s },
          Gem.ruby, File.expand_path("../fixtures/cloud_boot.rb", __dir__))

        expect(status.success?).to be(true), output
        expect(output).to include("CLOUD_BOOT_AND_REPORT_OK")
      end
    end
  end

  it "still eagerly loads embedded models, jobs and controllers with the local transport" do
    boot = <<~RUBY
      require #{File.expand_path("../dummy/config/application", __dir__).inspect}
      Rails.application.class.initializer "test.local_eager_load", after: :load_environment_config, before: :setup_main_autoloader do
        Rails.application.config.eager_load = true
      end
      Rails.application.initialize!
      %w[models/railwatch/telemetry_record.rb jobs/railwatch/rollup_job.rb controllers/railwatch/issues_controller.rb].each do |file|
        abort "local mode did not eager load " + file unless $LOADED_FEATURES.any? { |path| path.end_with?("/app/" + file) }
      end
      abort "wrong telemetry database" unless Railwatch::TelemetryRecord.connection_db_config.name == "railwatch_telemetry"
      puts "LOCAL_EAGER_LOAD_OK"
    RUBY
    output, status = Open3.capture2e(
      { "RAILS_ENV" => "test", "RAILWATCH_TRANSPORT" => "local" }, Gem.ruby, "-e", boot)

    expect(status.success?).to be(true), output
    expect(output).to include("LOCAL_EAGER_LOAD_OK")
  end
end
