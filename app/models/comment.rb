# frozen_string_literal: true

class Comment < RailwatchRecord
  SOURCES = %w[railwatch linear].freeze

  belongs_to :issue
  def user
    user_id && ::User.find_by(id: user_id)
  end

  def user=(u)
    self.user_id = u&.id
  end

  validates :body, presence: true
  validates :source, inclusion: { in: SOURCES }
  validates :user, presence: true, if: -> { source == "railwatch" }
  validates :author_name, presence: true, if: -> { source == "linear" }

  after_create :record_activity
  after_create_commit :enqueue_linear_sync

  private

  def record_activity
    issue.activities.create!(kind: "comment", user: user,
      data: { comment_id: id, body: body, source: source, author_name: author_name })
  end

  def enqueue_linear_sync
    nil unless source == "railwatch"
  end
end
