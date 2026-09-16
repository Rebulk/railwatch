# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
ENV["RAILWATCH_TOKEN"] = "test-token"
ENV["RAILWATCH_INGEST_URL"] = "http://railwatch.test"
ENV["RAILWATCH_ALLOW_HTTP"] = "true"
ENV["RAILWATCH_DEPLOY"] = "abc123"
ENV["RAILWATCH_LOG_LEVEL"] = "info"

require_relative "dummy/config/environment"
require "rspec/rails"
require "webmock/rspec"
require "railwatch/spec_helper"

ActiveRecord::Schema.verbose = false
load File.expand_path("dummy/db/schema.rb", __dir__)
# The engine's own two databases, for the embedded dashboard specs, built
# the way a host's db:prepare builds them: from the gem's migrations.
ActiveRecord::Migration.verbose = false
%w[railwatch railwatch_telemetry].each do |name|
  db_config = ActiveRecord::Base.configurations.configs_for(env_name: "test", name: name)
  ActiveRecord::Tasks::DatabaseTasks.with_temporary_connection(db_config) do |connection|
    connection.pool.migration_context.migrate
  end
end

WebMock.disable_net_connect!
# WebMock replaces ::Net::HTTP with a subclass whose #request short-circuits
# before calling super, so Railwatch's prepend on the real class never runs
# under WebMock. Re-prepend on the replacement so outgoing requests are still
# observed in this suite. Apps using WebMock in their own tests would do the same.
RSpec.configure do |config|
  config.before(:suite) { Net::HTTP.prepend(Railwatch::Patches::NetHttp) }
  # The Rake::Task patch is installed from the engine's rake_tasks hook, as
  # in a real rake process; the specs that execute tasks need it in place.
  config.before(:suite) { Rails.application.load_tasks }
  config.include Railwatch::SpecHelper
  config.include ActiveJob::TestHelper
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.order = :random
  config.expect_with(:rspec) { |c| c.syntax = :expect }

  # The beacon's per-IP counter lives in Rails.cache and every request spec
  # posts from 127.0.0.1, so a count that carried across the suite would
  # eventually trip the limit in an unrelated spec. Request specs only: the
  # dummy app's memory store makes this a hash reset, not I/O.
  config.before(:each, type: :request) { Rails.cache.clear }

  config.before(:each) do
    stub_request(:post, "http://railwatch.test/ingest").to_return do |request|
      accepted = Zlib::GzipReader.new(StringIO.new(request.body)).each_line.count
      { status: 200, body: JSON.generate(accepted: accepted, rejected: 0) }
    end
    stub_request(:get, %r{http://example\.test/}).to_return(status: 200, body: "hi", headers: { "Content-Length" => "2" })
    railwatch_transport
    Railwatch.config.sample = {
      requests: 1.0, jobs: 1.0, commands: 1.0, scheduled_tasks: 1.0,
      channels: 1.0, exceptions: 1.0
    }
  end
end
