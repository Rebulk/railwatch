# frozen_string_literal: true

module Railwatch
  # Turns newly ingested exception rows into Issues (create or bump), and
  # fires new / regressed alerts.
  class GroupExceptionsJob < ApplicationJob
    queue_as :default

    # A browser whose in-flight request died while kamal-proxy swapped
    # containers reports a network error a few seconds after the deploy
    # marker. That is the deploy working, not the app failing, and it opened
    # (then regressed) an issue on every deploy today. The exception rows are
    # still recorded; they just do not become an issue when they land inside
    # this window around a deploy. Same idea as CheckScheduledTasksJob's
    # DEPLOY_GRACE for missed runs.
    DEPLOY_GRACE = 3.minutes
    DEPLOY_NETWORK_ERRORS = %w[HttpNetworkError AxiosError InertiaException NetworkError TypeError:NetworkError].freeze

    def perform(environment, exception_ids)
      rows = environment.with_telemetry { Telemetry::Exception.where(id: exception_ids).to_a }
      rows = rows.reject { |row| deploy_swap_noise?(environment, row) }
      rows.group_by(&:group_hash).each do |group_hash, group|
        latest = group.max_by(&:occurred_at)
        issue, outcome = Issue.record_occurrence!(
          environment: environment, group_hash: group_hash, kind: "exception",
          title: "#{latest.class_name}: #{latest.message.to_s.first(200)}",
          culprit: [ latest.file, latest.line ].compact.join(":").presence,
          occurred_at: latest.occurred_at, deploy: latest.deploy, user_ref: latest.user_ref, source: latest.source,
          sample: { exception_id: latest.id, handled: latest.handled, execution_id: latest.execution_id,
                    execution_preview: latest.execution_preview, deploy: latest.deploy,
                    fingerprint: latest.fingerprint, fingerprint_source: latest.fingerprint_source })
        issue.increment!(:occurrences, group.size - 1) if group.size > 1
        update_affected_users(environment, issue) if affected_users_due?(issue, outcome)
        alert(issue, outcome)
      end
    end

    # The affected-user count is a DISTINCT over every retained occurrence of
    # the group, so on a busy issue it grows with the retention window and
    # used to run once per batch per group. Once per window per issue, and
    # always for a new issue, keeps the number fresh at a bounded cost.
    AFFECTED_USERS_WINDOW = 5.minutes
    AFFECTED_USERS_AT = Concurrent::Map.new

    private

    def affected_users_due?(issue, outcome)
      now = Time.current
      return AFFECTED_USERS_AT[issue.id] = now if outcome == :new

      last = AFFECTED_USERS_AT[issue.id]
      return false if last && now - last < AFFECTED_USERS_WINDOW

      AFFECTED_USERS_AT[issue.id] = now
    end

    def deploy_swap_noise?(environment, row)
      return false unless row.source == "browser" && DEPLOY_NETWORK_ERRORS.include?(row.class_name)

      last_deploy_at = environment.deploys.maximum(:deployed_at) or return false
      row.occurred_at.between?(last_deploy_at - DEPLOY_GRACE, last_deploy_at + DEPLOY_GRACE)
    end

    def update_affected_users(environment, issue)
      count = environment.with_telemetry { Telemetry::Exception.where(group_hash: issue.group_hash).where.not(user_ref: nil).distinct.count(:user_ref) }
      issue.update_columns(affected_users: count)
    end

    def alert(issue, outcome)
      event = { new: "new_issue", regressed: "regressed_issue" }[outcome] or return
      payload = { issue_key: issue.key, title: issue.title, environment: issue.environment.name }
      issue.application.alert_rules.where(event: event).find_each do |rule|
        next unless rule.matches?(issue: issue, payload: payload)
        rule.fire!(event: event, issue: issue, payload: payload)
      end
    end
  end
end
