# frozen_string_literal: true

# A fresh process is essential, and so is the ordering: a rake process
# invokes its top-level task -- which is where the command patch starts the
# execution, and sampling it builds the reporter -- before that task's
# `:environment` prerequisite boots Rails and runs config/initializers. An
# embedded app with a token in its environment is enabled, and therefore
# choosing a transport, while its config still says HTTP.
require "bundler/setup"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "rake"
require "railwatch"

class RakeBootApplication < Rails::Application
  config.load_defaults 8.1
  config.root = ENV.fetch("RAKE_BOOT_ROOT")
  config.eager_load = false
  config.secret_key_base = "rake-boot-test"
  config.logger = Logger.new(IO::NULL)
  config.cache_store = :memory_store
  config.hosts.clear
end

# What `Rails.application.load_tasks` does for the engine, at the point rake
# does it: the Rakefile has required config/application, but nothing has
# called initialize!.
Railwatch::Patches.install_rake_task!

Rake::Task.define_task(:environment) { Rails.application.initialize! }
Rake::Task.define_task(rake_boot_probe: :environment) { Railwatch.record(:log, level: "info", message: "from rake") }

abort "nothing to prove: a reporter existed before the task was invoked" unless Railwatch.instance_variable_get(:@reporter).nil?

Rake::Task["rake_boot_probe"].invoke

abort "the command patch never ran: no reporter was built" if Railwatch.instance_variable_get(:@reporter).nil?
abort "config did not end up embedded" unless Railwatch.config.local?

transport = Railwatch.reporter.instance_variable_get(:@transport)
if transport.is_a?(Railwatch::Transport::Http)
  abort "an embedded app's rake task is reporting over HTTP: telemetry bypasses the app's own " \
        "database and the export queue, so it earns no replay receipt"
end

puts "RAKE_BOOT_TRANSPORT_OK #{transport.class}"
