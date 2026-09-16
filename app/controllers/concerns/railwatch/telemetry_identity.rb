# frozen_string_literal: true

# Builds identity props from the current environment's telemetry database.
# Callers must already be inside `telemetry { }`; this keeps Person lookups
# batched and prevents a reference from ever being resolved in another
# environment's tenant database.
module Railwatch
  module TelemetryIdentity
    private

    def origin_people(rows)
      refs = rows.filter_map(&:user_ref).uniq
      refs.empty? ? {} : Telemetry::Person.where(ref: refs).index_by(&:ref)
    end

    def origin_identity(record, people)
      person = people[record.user_ref]
      {
        user_ref: record.user_ref,
        tenant: record.app_tenant,
        person: person && { ref: person.ref, name: person.display_name }
      }
    end
  end
end
