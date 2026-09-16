# frozen_string_literal: true

# One entry in an issue's timeline: a comment or a system event (status
# change, priority change, reassignment, merge/unmerge, split, regression,
# alert sent). `data` holds kind-specific details the frontend renders into a
# sentence.
class IssueActivity < RailwatchRecord
  KINDS = %w[created status priority assignee comment merge absorbed unmerge split regressed alert agent].freeze

  belongs_to :issue
  def user
    user_id && ::User.find_by(id: user_id)
  end

  def user=(u)
    self.user_id = u&.id
  end

  validates :kind, inclusion: { in: KINDS }
end
