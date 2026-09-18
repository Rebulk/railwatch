# frozen_string_literal: true

module Railwatch
  # Auto-resolves open issues that have gone quiet for a configured number of
  # days (nil = off). Resolved with no deploy attached, so any recurrence is
  # treated as a regression rather than a duplicate. Runs daily (recurring.yml).
  class AutoResolveIssuesJob < ApplicationJob
    queue_as :default

    def perform
      days = Railwatch::Embedded::Account.auto_resolve_after_days
      return unless days

      Issue.open.where("last_seen_at < ?", days.days.ago).find_each do |issue|
        issue.resolve!(deploy: nil)
      end
    end
  end
end
