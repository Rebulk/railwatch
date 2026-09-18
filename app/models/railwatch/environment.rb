# frozen_string_literal: true

module Railwatch
  # The one environment an embedded install monitors: the host application in
  # its current Rails.env. Not a table. The hosted platform's Environment is an
  # account-scoped Active Record row with a token, quota and pause state; the
  # telemetry, ingest and dashboard code only ever asks it for an id, a slug,
  # a name, with_telemetry, and a few display attributes, so this stands in
  # with exactly that surface.
  class Environment
    ID = 1

    attr_reader :id, :name, :slug, :application_name

    def self.current = @current ||= new

    def self.find(id)
      raise ActiveRecord::RecordNotFound, "Environment #{id}" unless id.to_i == ID
      current
    end

    def initialize
      @id = ID
      @name = Rails.env.to_s
      @application_name = Rails.application.class.module_parent_name
      @slug = "#{@application_name.parameterize}-#{@name}"
    end

    def with_telemetry(&block) = TelemetryRecord.with_tenant(slug, &block)
    def telemetry_exists? = true
    def paused? = false
    def token_prefix = "embedded"
    def retention_days = 7
    def last_seen_at = Railwatch::Embedded.last_seen_at
    def application = Application.current
    def issues = Issue.where(environment_id: ID)
    def deploys = Deploy.where(environment_id: ID)
    def saved_views = SavedView.where(environment_id: ID)
    def thresholds = Threshold.where(environment_id: ID)
    def anomaly_rules = AnomalyRule.where(environment_id: ID)
    def events_this_month = 0
    # The platform lets an account list the servers it expects to report so the
    # dashboard can flag silent ones. One embedded install is its own server.
    def expected_servers = []

    # Ingest::Batch touches this in embedded mode; there is no row to update.
    def update_columns(last_seen_at:) = Railwatch::Embedded.last_seen_at = last_seen_at

    # GlobalID for Active Job arguments (RollupJob.perform_later(environment, bucket)).
    include GlobalID::Identification
    def to_global_id(...) = GlobalID.create(self, app: "railwatch")
    def self.find_by_id(id) = find(id)
  end
end
