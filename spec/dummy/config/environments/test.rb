Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = false
  config.consider_all_requests_local = false
  config.action_dispatch.show_exceptions = :all
  config.active_support.deprecation = :stderr
  config.action_controller.allow_forgery_protection = false
  config.logger = ActiveSupport::Logger.new(nil)
  config.log_level = :info
  config.active_storage.service = :test
end
