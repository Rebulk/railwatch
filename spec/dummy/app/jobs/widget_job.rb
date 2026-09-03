class WidgetJob < ActiveJob::Base
  queue_as :default

  def perform(name, fail: false)
    Widget.where(name: name).to_a
    raise "widget job failed: #{name}" if fail
    Rails.logger.info("performed #{name}")
  end
end
