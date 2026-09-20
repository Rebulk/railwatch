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
    # Deliberately read from the telemetry database rather than held in this
    # process. A deployed embedded install ingests in the writer process and
    # renders the dashboard in a web one, so a value set during ingest is
    # invisible to the page that needs it -- and a nil here is what the
    # dashboard treats as "no events yet", so it showed its install steps no
    # matter how much had been recorded. The newest batch row is the same
    # fact, in the file both processes already share, one indexed lookup away.
    def last_seen_at
      with_telemetry { Telemetry::IngestBatch.order(id: :desc).limit(1).pick(:received_at) }
    end
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

    # Ingest::Batch touches this after writing a batch. Nothing to record: the
    # batch row it just wrote is what last_seen_at reads.
    def update_columns(last_seen_at:) = nil

    # GlobalID for Active Job arguments (RollupJob.perform_later(environment, bucket)).
    include GlobalID::Identification
    def to_global_id(...) = GlobalID.create(self, app: "railwatch")
    def self.find_by_id(id) = find(id)
  end
end
