# frozen_string_literal: true

# Fired-alert history. Reachable two ways: account-wide at /alerts (every
# environment) and, nested under an environment, scoped to that
# environment's issues. AlertRule (and so Alert) belongs to an application
# rather than an environment, so the env-scoped view filters through the
# alert's issue instead -- app-level alerts with no issue (e.g. quota) only
# show up in the account-wide view.
module Railwatch
    class AlertsController < DashboardController
    # One environment in an embedded install, so the account-wide and the
    # environment-scoped listing are the same page; the base class already
    # set the environment and shares its props.

    def index
      scope = account_alerts
      scope = scope.joins(:issue).where(railwatch_issues: { environment_id: environment.id }) if params[:environment_id]
      fields = FilterQuery.parse(params[:q]).fetch(:fields)
      scope = scope.where(event: fields["event"]) if AlertRule::EVENTS.include?(fields["event"].to_s)
      scope = scope.where(status: fields["status"]) if Alert::STATUSES.include?(fields["status"].to_s)
      alerts = scope.order(created_at: :desc).limit(200)
      render inertia: { alerts: alerts.map { |a| row(a) }, q: params[:q].to_s, statuses: Alert::STATUSES }
    end

    def retry
      alert = account_alerts.find(params[:id])
      if alert.retry_delivery!
        redirect_back fallback_location: alerts_path, notice: "Retrying alert"
      else
        redirect_back fallback_location: alerts_path, alert: "Only failed alerts can be retried"
      end
    end

    private

    # Scoped through the integration rather than the rule's application: a
    # "Send test" alert has no rule, and its destination is what owns it.
    def account_alerts
      Alert.all
    end

    def row(a)
      { id: a.id, event: a.event, status: a.status, sent_at: a.sent_at, error: a.error, payload: a.payload, created_at: a.created_at,
        integration: { kind: a.integration.kind, name: a.integration.name },
        issue: a.issue && { id: a.issue.id, key: a.issue.key, title: a.issue.title } }
    end
    end
end
