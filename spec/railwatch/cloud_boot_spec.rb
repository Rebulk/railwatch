# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

RSpec.describe "a production boot" do
  [ [ true, false ], [ false, false ], [ false, true ] ].each do |check_schema_cache, solid_queue|
    it "boots and reports over HTTP (schema version check: #{check_schema_cache}, Solid Queue: #{solid_queue})" do
      Dir.mktmpdir("railwatch-cloud-boot") do |root|
        FileUtils.mkdir_p("#{root}/config/initializers")
        FileUtils.mkdir_p("#{root}/app/controllers")
        File.write("#{root}/app/controllers/application_controller.rb", "class ApplicationController < ActionController::Base; end\n")
        File.write("#{root}/config/database.yml", "production:\n  adapter: sqlite3\n  database: ':memory:'\n")
        File.write("#{root}/config/initializers/railwatch.rb", <<~RUBY)
          Railwatch.configure do |config|
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
end
