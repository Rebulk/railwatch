class ConcurrentJob < ActiveJob::Base
  limits_concurrency key: ->(*) { "widget" }

  def perform
  end
end
