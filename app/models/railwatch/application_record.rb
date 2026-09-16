# frozen_string_literal: true

module Railwatch
  # Base class for what the engine owns about the monitored application besides
  # telemetry: issues and their comments and activity, deploys, saved views,
  # thresholds, anomaly rules, alert rules and alerts. These are authored and
  # permanent where telemetry is derived and pruned, so they live in their own
  # database (`railwatch` in the host's database.yml) and never in the host's
  # primary.
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
    connects_to database: { writing: :railwatch, reading: :railwatch }
  end
end
