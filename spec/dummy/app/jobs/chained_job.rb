class ChainedJob < ActiveJob::Base
  def perform
    WidgetJob.perform_later("chained")
  end
end
