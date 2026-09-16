# frozen_string_literal: true

module Railwatch
  class PerformanceScanJob < ApplicationJob
    queue_as :default

    def perform
      [ Environment.current ].each { |env| DetectPerformanceIssuesJob.perform_later(env) }
    end
  end
end
