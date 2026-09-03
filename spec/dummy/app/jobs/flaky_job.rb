class FlakyJob < ActiveJob::Base
  retry_on RuntimeError, wait: 0, attempts: 2

  def perform
    raise "flaky"
  end
end
