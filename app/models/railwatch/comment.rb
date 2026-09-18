# frozen_string_literal: true

module Railwatch
  class Comment < ApplicationRecord
    self.table_name = "railwatch_comments"
    SOURCES = %w[railwatch linear].freeze

    belongs_to :issue
    def user
      viewer_id && User.find_by(id: viewer_id)
    end

    def user=(u)
      self.viewer_id = u&.id&.to_s
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
end
