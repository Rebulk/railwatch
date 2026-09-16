# frozen_string_literal: true

module Railwatch
  class Deploy < ApplicationRecord
    self.table_name = "railwatch_deploys"
    def environment = Environment.current

    validates :deploy, presence: true, uniqueness: { scope: :environment_id }
    validates :deployed_at, presence: true
    # Rendered as the "Open" link on the deploy page. Same rule as
    # Application#repository_url, checked by parsing: one whole http(s) URL
    # with a host, so a hook (or whoever holds its token) cannot put a
    # javascript:/data: link, a hostless "https://?x", or an arbitrary
    # off-site destination behind a trusted button.
    validate :url_is_a_web_address

    scope :recent, -> { order(deployed_at: :desc) }
    scope :between, ->(from, to) { where(deployed_at: from..to) }

    before_validation :assign_previous_ref
    before_validation :trim_commits

    def short_ref
      ref.to_s.first(7).presence || deploy.first(12)
    end

    def commits_count
      commits.size
    end

    # The deploy immediately before this one in the same environment.
    def previous_deploy
      environment.deploys.where(deployed_at: ...deployed_at).recent.first
    end

    # The stretch of time this release was live: from its own deploy until the
    # next one, or until now for the current release. Release health is summed
    # over this, not over the page's window.
    def window
      [ deployed_at, environment.deploys.where("deployed_at > ?", deployed_at).order(:deployed_at).first&.deployed_at || Time.current ]
    end

    private

    def url_is_a_web_address
      return if url.blank?
      parsed = url.match?(/\A\S+\z/) ? URI.parse(url) : nil
      return if parsed.is_a?(URI::HTTP) && parsed.host.present?
      errors.add(:url, "must be a single http:// or https:// URL")
    rescue URI::InvalidURIError
      errors.add(:url, "must be a single http:// or https:// URL")
    end

    def assign_previous_ref
      return if previous_ref.present? || deployed_at.blank?
      self.previous_ref = previous_deploy&.ref
    end

    # The post-deploy hook sends its most recent commits (newest first) without
    # knowing where the last deploy stopped, so cut the list at that commit.
    def trim_commits
      return if previous_ref.blank?
      index = commits.index { |c| c["sha"].to_s.start_with?(previous_ref) }
      self.commits = commits.first(index) if index
    end
  end
end
