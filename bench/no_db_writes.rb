# frozen_string_literal: true

# Gate: the gem must never write to the application's database. Drives 50
# instrumented requests and fails if any INSERT/UPDATE/DELETE was issued from
# a frame inside lib/lantern.
#
#   bundle exec ruby bench/no_db_writes.rb
#
ENV["RAILS_ENV"] = "test"
ENV["LANTERN_TOKEN"] = "bench"
ENV["LANTERN_INGEST_URL"] = "http://127.0.0.1:9"
require_relative "../spec/dummy/config/environment"
require "rack/test"

ActiveRecord::Schema.verbose = false
load File.expand_path("../spec/dummy/db/schema.rb", __dir__)
3.times { |i| Widget.create!(name: "w#{i}", gadget: Gadget.create!(name: "g#{i}")) }
Lantern.reporter.define_singleton_method(:flush) { @buffer.drain; nil }

gem_root = File.expand_path("..", __dir__) + "/lib/lantern"
offenders = []
ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
  sql = event.payload[:sql].to_s
  next unless sql.match?(/\A\s*(INSERT|UPDATE|DELETE)/i)
  frame = caller_locations(0, 60).find { |l| l.path.start_with?(gem_root) }
  offenders << "#{sql[0, 80]} <- #{frame.path.delete_prefix(gem_root)}:#{frame.lineno}" if frame
end

class Driver
  include Rack::Test::Methods
  def app = Rails.application
end
driver = Driver.new
50.times do
  driver.get "/widgets"
  driver.get "/boom"
  driver.get "/enqueue"
  driver.get "/cached"
end
WidgetJob.perform_now("bench")

if offenders.empty?
  puts "NO DB WRITES FROM LANTERN: PASSED (200 requests + 1 job)"
else
  puts "LANTERN WROTE TO THE APP DATABASE:"
  offenders.uniq.first(10).each { |o| puts "  #{o}" }
  exit 1
end
