# frozen_string_literal: true

module Railwatch
  module Telemetry
    # Hourly release health per deploy, recomputed from raw `sessions` rows by
    # ReleaseHealthRollupJob. The deploy *is* the release -- the gem stamps it
    # on every record it ships -- so counting sessions per deploy is all this
    # needs. Sentry's crash-free session rate, crash-free user rate, and
    # adoption, over the same data.
    #
    # A session that spans two hours is counted in both buckets, like every
    # other rollup here: the bucket, not the session, is the unit these numbers
    # sum over. Every method must run inside environment.with_telemetry { }.
    class ReleaseHealth < TelemetryRecord
      self.table_name = "release_health"

      scope :between, ->(from, to) { where(bucket: from.beginning_of_hour..to) }
      # A nil deploy means "every release in the window", which is what the
      # index page's headline numbers are.
      scope :for_release, ->(deploy) { deploy ? where(deploy: deploy) : all }

      TOTALS = %i[sessions sessions_errored sessions_crashed users users_crashed duration_sum duration_count].freeze

      # Window totals for one release. Rates come back nil, not zero, when there
      # is nothing to divide by, so an environment with no sessions yet never
      # renders as "0% crash-free".
      def self.for_deploy(deploy, from, to)
        sessions, errored, crashed, users, users_crashed, duration_sum, duration_count =
          between(from, to).for_release(deploy).pick(*TOTALS.map { |column| Arel.sql("COALESCE(SUM(#{column}), 0)") })
        {
          sessions: sessions, users: users,
          crash_free_sessions: rate(sessions - crashed, sessions),
          crash_free_users: rate(users - users_crashed, users),
          errored: rate(errored, sessions),
          avg_duration_ms: duration_count.zero? ? nil : (duration_sum / duration_count / 1000.0).round(2)
        }
      end

      # Hourly points for the stacked sessions-by-status chart.
      def self.series(deploy, from, to)
        between(from, to).for_release(deploy).group(:bucket).order(:bucket)
          .pluck(:bucket, Arel.sql("SUM(sessions)"), Arel.sql("SUM(sessions_errored)"), Arel.sql("SUM(sessions_crashed)"))
          .map { |bucket, sessions, errored, crashed|
            { t: bucket, sessions: sessions, ok: sessions - errored - crashed, errored: errored, crashed: crashed }
          }
      end

      # Each release's share of the window's sessions, as a percentage -- how
      # far a new release has rolled out.
      def self.adoption(from, to)
        counts = between(from, to).group(:deploy).sum(:sessions)
        total = counts.values.sum
        return counts.transform_values { 0.0 } if total.zero?
        counts.transform_values { |n| (n * 100.0 / total).round(1) }
      end

      def self.rate(numerator, denominator)
        return nil if denominator.to_i.zero?
        (numerator * 100.0 / denominator).round(2)
      end
    end
  end
end
