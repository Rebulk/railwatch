# frozen_string_literal: true

module Railwatch
  class ScheduledTaskScanJob < ApplicationJob
    queue_as :default

    def perform
      [ Environment.current ].each { |env| CheckScheduledTasksJob.perform_later(env) }
    end
  end
end
