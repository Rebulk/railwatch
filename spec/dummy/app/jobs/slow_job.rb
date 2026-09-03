class SlowJob < ActiveJob::Base
  def perform
    sleep 0.05
  end
end
