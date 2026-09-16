# frozen_string_literal: true

# The one application an embedded install monitors: the host. Not a table.
# Issue keys need a prefix and a counter; the rest of what the platform's
# Application carries (account, repository links, alert rules) is either
# fixed here or empty.
class Application
  ID = 1

  attr_reader :id, :name, :slug

  def self.current = @current ||= new
  def self.find(id)
    raise ActiveRecord::RecordNotFound, "Application #{id}" unless id.to_i == ID
    current
  end

  def initialize
    @id = ID
    @name = Rails.application.class.module_parent_name
    @slug = @name.parameterize
  end

  def issue_prefix = Railwatch.config.issue_prefix || @name.upcase.gsub(/[^A-Z0-9]/, "")[0, 4].presence || "APP"
  def repository_url = Railwatch.config.repository_url
  def default_branch = "main"
  def environments = [ Environment.current ]
  def alert_rules = AlertRule.where(application_id: ID)
  def account = Railwatch::Embedded::Account
  def issues = Issue.where(application_id: ID)

  # Issue numbers are per application on the platform (APP-1, APP-2, ...),
  # allocated under a row lock on the application. There is no row here, so
  # the meta database's own write lock serialises it: Issue creation already
  # runs inside a transaction, and SQLite allows one writer.
  def next_issue_number!
    (Issue.where(application_id: ID).maximum(:number) || 0) + 1
  end

  include GlobalID::Identification
  def to_global_id(...) = GlobalID.create(self, app: "railwatch")
end
