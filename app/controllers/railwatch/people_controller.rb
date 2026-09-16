# frozen_string_literal: true

module Railwatch
    class PeopleController < DashboardController
    def index
      from, to = window_range
      active = telemetry do
        Telemetry::Execution.requests.between(from, to).where.not(user_ref: nil).group(:user_ref)
          .pluck(:user_ref, Arel.sql("COUNT(*)"), Arel.sql("SUM(CASE WHEN status >= 500 THEN 1 ELSE 0 END)"), Arel.sql("MAX(occurred_at)"))
          .map { |ref, c, e, last| { ref: ref, requests: c, errors: e, last_seen_at: last } }.sort_by { |r| -r[:requests] }.first(200)
      end
      people = telemetry { Telemetry::Person.where(ref: active.map { |a| a[:ref] }).index_by(&:ref) }
      render inertia: { people: active.map { |a| a.merge(name: people[a[:ref]]&.display_name, email: people[a[:ref]]&.email, tenant: people[a[:ref]]&.app_tenant) } }
    end

    def show
      ref = params[:id]
      person = telemetry { Telemetry::Person.find_by(ref: ref) }
      executions = telemetry { Telemetry::Execution.where(user_ref: ref).between(*window_range).recent.limit(100).map { |r| { execution_id: r.execution_id, kind: r.kind, name: r.name, status: r.status, outcome: r.outcome, duration: r.duration_ms.round(1), occurred_at: r.occurred_at, exception_preview: r.exception_preview } } }
      exception_groups = telemetry { Telemetry::Exception.where(user_ref: ref).between(*window_range).group(:group_hash).count }
      issues = environment.issues.where(group_hash: exception_groups.keys).map { |i| { id: i.id, key: i.key, title: i.title, status: i.status, count: exception_groups[i.group_hash] } }
      render inertia: { person: person && { person_ref: person.ref, name: person.display_name, email: person.email, tenant: person.app_tenant, first_seen_at: person.first_seen_at, last_seen_at: person.last_seen_at }, person_ref: ref, executions: executions, issues: issues }
    end
    end
end
