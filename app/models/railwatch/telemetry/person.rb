# frozen_string_literal: true

module Railwatch
  module Telemetry
    # A monitored application's user, as seen in telemetry. Keyed by ref
    # ("tenant:id" or "id") so the same person across tenants stays distinct.
    class Person < TelemetryRecord
      scope :recent, -> { order(last_seen_at: :desc) }

      def self.touch_from_record(rec, at:)
        touch_all([ [ rec, at ] ])
        find_by(ref: rec["id"].to_s)
      end

      # One upsert per batch instead of a find-and-save per user record: the
      # gem emits a user record once per user per hour per process, so a busy
      # batch carries dozens. ON CONFLICT keeps first_seen_at and only
      # overwrites name/email/tenant when the new value is present.
      def self.touch_all(pairs)
        rows = pairs.filter_map do |rec, at|
          ref = rec["id"].to_s
          next if ref.empty?
          { ref: ref, name: rec["name"].presence, email: rec["email"].presence, app_tenant: rec["tenant"].presence,
            first_seen_at: at, last_seen_at: at, requests_count: 0, exceptions_count: 0 }
        end
        return 0 if rows.empty?

        # Latest timestamp wins when the same ref repeats within a batch.
        rows = rows.group_by { |r| r[:ref] }.map { |_ref, dup| dup.max_by { |r| r[:last_seen_at] } }
        upsert_all(rows, unique_by: :ref, record_timestamps: false,
                   on_duplicate: Arel.sql(<<~SQL.squish))
                     name = COALESCE(excluded.name, people.name),
                     email = COALESCE(excluded.email, people.email),
                     app_tenant = COALESCE(excluded.app_tenant, people.app_tenant),
                     first_seen_at = COALESCE(people.first_seen_at, excluded.first_seen_at),
                     last_seen_at = MAX(people.last_seen_at, excluded.last_seen_at)
                   SQL
        rows.size
      end

      def executions
        Execution.where(user_ref: ref)
      end

      def display_name
        name.presence || email.presence || ref
      end
    end
  end
end
