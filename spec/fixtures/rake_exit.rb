# frozen_string_literal: true

# A real process, exiting for real, against a real socket. Both facts this
# guards are about what happens on the way out of a cloud-only process, and
# neither survives being stubbed: the delivery happens on the reporter's own
# thread, and the bound is a join in an at_exit handler.
#
# RAKE_EXIT_PORT points at a server the spec controls. `hung` accepts the
# connection and never answers, which is what a wedged receiver does and what
# an unreachable one does not -- a refused connection fails fast and proves
# nothing.
require "bundler/setup"
require "rails"
require "active_record/railtie"
require "rake"
require "railwatch"

class RakeExitApplication < Rails::Application
  config.load_defaults 8.1
  config.root = ENV.fetch("RAKE_EXIT_ROOT")
  config.eager_load = false
  config.secret_key_base = "rake-exit-test"
  config.logger = Logger.new(IO::NULL)
  config.hosts.clear
end

Railwatch.configure do |c|
  c.transport = :http
  c.token = "rake-exit-token"
  c.ingest_url = "http://127.0.0.1:#{ENV.fetch('RAKE_EXIT_PORT')}"
end

Railwatch::Patches.install_rake_task!
Rake::Task.define_task(:environment) { Rails.application.initialize! }
Rake::Task.define_task(rake_exit_probe: :environment) do
  raise ArgumentError, "cron job died"
end

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
begin
  Rake::Task["rake_exit_probe"].invoke
rescue ArgumentError
  # The point is what the task's failure costs on the way out, not the failure.
end
# Printed before at_exit runs, so the spec can tell the task's own cost apart
# from the bounded shutdown that follows it.
warn "TASK_RETURNED_AFTER=#{Process.clock_gettime(Process::CLOCK_MONOTONIC) - started}"

at_exit { warn "PROCESS_EXITING_AFTER=#{Process.clock_gettime(Process::CLOCK_MONOTONIC) - started}" }
