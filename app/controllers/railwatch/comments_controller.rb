# frozen_string_literal: true

module Railwatch
    class CommentsController < DashboardController
    def create
      issue = Issue.all.find(params[:issue_id])
      issue.comments.create!(user: ::Current.user, body: params.require(:body))
      redirect_to issue_path(issue), notice: "Comment added"
    end
    end
end
