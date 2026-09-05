# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
ENV["LANTERN_TOKEN"] = "test-token"
ENV["LANTERN_INGEST_URL"] = "http://lantern.test"
ENV["LANTERN_DEPLOY"] = "abc123"
ENV["LANTERN_LOG_LEVEL"] = "info"

require_relative "dummy/config/environment"
require "rspec/rails"
require "webmock/rspec"
require "lantern/spec_helper"

ActiveRecord::Schema.verbose = false
load File.expand_path("dummy/db/schema.rb", __dir__)

WebMock.disable_net_connect!
# WebMock replaces ::Net::HTTP with a subclass whose #request short-circuits
# before calling super, so Lantern's prepend on the real class never runs
# under WebMock. Re-prepend on the replacement so outgoing requests are still
# observed in this suite. Apps using WebMock in their own tests would do the same.
RSpec.configure do |config|
  config.before(:suite) { Net::HTTP.prepend(Lantern::Patches::NetHttp) }
  config.include Lantern::SpecHelper
  config.include ActiveJob::TestHelper
  config.use_transactional_fixtures = true
  config.infer_spec_type_from_file_location!
  config.order = :random
  config.expect_with(:rspec) { |c| c.syntax = :expect }

  config.before(:each) do
    stub_request(:post, "http://lantern.test/ingest").to_return do |request|
      accepted = Zlib::GzipReader.new(StringIO.new(request.body)).each_line.count
      { status: 200, body: JSON.generate(accepted: accepted, rejected: 0) }
    end
    stub_request(:get, %r{http://example\.test/}).to_return(status: 200, body: "hi", headers: { "Content-Length" => "2" })
    lantern_transport
    Lantern.config.sample = { requests: 1.0, jobs: 1.0, commands: 1.0, scheduled_tasks: 1.0, exceptions: 1.0 }
  end
end
