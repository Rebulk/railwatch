class AbortedJob < ActiveJob::Base
  before_perform { throw :abort }

  def perform
  end
end
