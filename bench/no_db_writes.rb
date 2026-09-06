# frozen_string_literal: true

# Gate: the gem must never write to the application's database. Drives 50
# instrumented requests and fails if any INSERT/UPDATE/DELETE was issued from
# a frame inside lib/nightrail.
#
#   bundle exec ruby bench/no_db_writes.rb
#
require_relative "support"

gem_root = File.expand_path("..", __dir__) + "/lib/nightrail"
offenders = []
ActiveSupport::Notifications.subscribe("sql.active_record") do |event|
  sql = event.payload[:sql].to_s
  next unless sql.match?(/\A\s*(INSERT|UPDATE|DELETE)/i)
  frame = caller_locations(0, 60).find { |l| l.path.start_with?(gem_root) }
  offenders << "#{sql[0, 80]} <- #{frame.path.delete_prefix(gem_root)}:#{frame.lineno}" if frame
end

50.times do
  DRIVER.get "/widgets"
  DRIVER.get "/boom"
  DRIVER.get "/enqueue"
  DRIVER.get "/cached"
end
WidgetJob.perform_now("bench")

if offenders.empty?
  puts "NO DB WRITES FROM NIGHTRAIL: PASSED (200 requests + 1 job)"
else
  puts "NIGHTRAIL WROTE TO THE APP DATABASE:"
  offenders.uniq.first(10).each { |o| puts "  #{o}" }
  exit 1
end
