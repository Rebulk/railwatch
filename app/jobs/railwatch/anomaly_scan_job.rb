# frozen_string_literal: true

module Railwatch
  class AnomalyScanJob < ApplicationJob
    queue_as :default

    def perform
      DetectAnomaliesJob.perform_later(Environment.current) if AnomalyRule.where(enabled: true).exists?
    end
  end
end
