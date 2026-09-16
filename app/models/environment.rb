# frozen_string_literal: true

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
  def last_seen_at = Railwatch::Embedded.last_seen_at
  def issues = Railwatch::Embedded::NONE
  def deploys = Railwatch::Embedded::NONE

  # Ingest::Batch touches this in embedded mode; there is no row to update.
  def update_columns(last_seen_at:) = Railwatch::Embedded.last_seen_at = last_seen_at

  # GlobalID for Active Job arguments (RollupJob.perform_later(environment, bucket)).
  include GlobalID::Identification
  def to_global_id(...) = GlobalID.create(self, app: "railwatch")
  def self.find_by_id(id) = find(id)
end
