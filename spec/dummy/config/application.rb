# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"
require "action_cable/engine"

Bundler.require(*Rails.groups)
require "nightrail"

module Dummy
  class Application < Rails::Application
    config.load_defaults 8.1
    config.eager_load = false
    config.active_job.queue_adapter = :test
    config.cache_store = :memory_store
    config.action_mailer.delivery_method = :test
    config.action_mailer.perform_deliveries = true
    config.active_record.strict_loading_by_default = false
    config.hosts.clear
    config.secret_key_base = "dummy"
    config.solid_queue.connects_to = { database: { writing: :queue } }
    config.filter_parameters += [ :secret_code ]
  end
end
