# frozen_string_literal: true

# What one unhandled exception costs on the request thread: the whole
# /boom request with Railwatch off and on, in each configuration that
# changes the work, then Exceptions.capture and its parts in isolation.
#
#   bundle exec ruby bench/exception_path.rb
require_relative "support"

stub_reporter_writes!

# The error subscriber is not a Notifications subscriber, so support.rb's
# railwatch_off!/on! do not cover it.
def error_subscriber_off! = Rails.error.unsubscribe(Railwatch::Subscribers::Exceptions::ErrorSubscriber)
def error_subscriber_on! = Rails.error.subscribe(Railwatch::Subscribers::Exceptions::ErrorSubscriber.new)

rows = []
railwatch_off!
error_subscriber_off!
rows << [ "GET /boom, Railwatch off (Rails renders the 500)", per_call(200) { DRIVER.get("/boom") } ]
railwatch_on!
error_subscriber_on!
rows << [ "GET /boom, Railwatch on (sampled in)", per_call(200) { DRIVER.get("/boom") } ]
Railwatch.config.capture_exception_source = false
rows << [ "GET /boom, Railwatch on, capture_exception_source = false", per_call(200) { DRIVER.get("/boom") } ]
Railwatch.config.capture_exception_source = true
Railwatch.config.sample[:requests] = 0.0
rows << [ "GET /boom, Railwatch on, sampled out (exception still ships)", per_call(200) { DRIVER.get("/boom") } ]
Railwatch.config.sample[:requests] = 1.0

# A real error object from the real request, so the backtrace is the
# framework-deep one production sees.
caught = []
Rails.error.subscribe(Class.new { define_method(:report) { |e, **| caught << e } }.new)
DRIVER.get("/boom")
error = caught.last or abort "no error captured"
exe = Railwatch.start_execution(source: :request, sample_kind: :requests, preview: "bench")
exe.enter_stage(:action)
rows << [ "  Backtrace.frames(error, with_source: true)", per_call(500) { Railwatch::Backtrace.frames(error, with_source: true) } ]
rows << [ "  Backtrace.frames(error, with_source: false)", per_call(500) { Railwatch::Backtrace.frames(error, with_source: false) } ]
rows << [ "  Exceptions.capture (handled, source on)", per_call(500) { Railwatch::Subscribers::Exceptions.capture(error, handled: true, severity: :warning); exe.instance_variable_set(:@exception_states, nil); exe.records.clear } ]
rows << [ "  Exceptions.ignored?(error) (ancestor walk x #{Railwatch.config.ignored_exceptions.size} names)", per_call(5000) { Railwatch::Subscribers::Exceptions.ignored?(error) } ]
rows << [ "  normalize_message(msg)", per_call(5000) { Railwatch::Subscribers::Exceptions.normalize_message("kaboom for user 42 at https://x.test/a?b=1") } ]
puts "backtrace depth: #{error.backtrace.size}, in_app frames: #{Railwatch::Backtrace.frames(error, with_source: false).count { |f| f[:in_app] }}"
print_rows(rows)
