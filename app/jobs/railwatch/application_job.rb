# frozen_string_literal: true

module Railwatch
  # The engine's jobs run on whatever Active Job adapter the host configured.
  class ApplicationJob < ActiveJob::Base
  end
end
