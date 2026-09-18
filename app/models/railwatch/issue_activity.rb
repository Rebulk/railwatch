# frozen_string_literal: true

module Railwatch
  # One entry in an issue's timeline: a comment or a system event (status
  # change, priority change, reassignment, merge/unmerge, split, regression,
  # alert sent). `data` holds kind-specific details the frontend renders into a
  # sentence.
  class IssueActivity < ApplicationRecord
    self.table_name = "railwatch_issue_activities"
    KINDS = %w[created status priority assignee comment merge absorbed unmerge split regressed alert agent].freeze

    belongs_to :issue
    def user
      viewer_id && User.find_by(id: viewer_id)
    end

    def user=(u)
      self.viewer_id = u&.id&.to_s
    end

    validates :kind, inclusion: { in: KINDS }
  end
end
