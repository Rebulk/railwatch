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
    begin
      connects_to database: { writing: :railwatch, reading: :railwatch }
    rescue ActiveRecord::AdapterNotSpecified, LoadError
      # No `railwatch` entry in this environment's database.yml, or an entry
      # whose adapter gem is not in the bundle yet (LoadError). A cloud-transport
      # app has none and still eager-loads this class in production, and so
      # does the --local installer's own boot, before it has written the
      # entry -- so loading must not raise. Using it must, though: without
      # connects_to this class would inherit ActiveRecord::Base's PRIMARY
      # connection, and its tables are unprefixed, so a query would read and
      # a write would corrupt the host application's own tables. Every route
      # into the connection goes through connection_pool, so refusing here
      # fails closed for reads and writes alike.
      def self.connection_pool
        raise Railwatch::DatabaseNotConfigured,
              "the `railwatch` database (issues, comments, saved views and deploys) is not configured for the " \
              "#{Rails.env} environment; run `bin/rails generate railwatch:install --local` " \
              "or add it to config/database.yml (docs/embedded.md)"
      end
    end
  end
end
