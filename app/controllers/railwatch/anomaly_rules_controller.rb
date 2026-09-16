# frozen_string_literal: true

module Railwatch
    class AnomalyRulesController < DashboardController
    def create
      rule = environment.anomaly_rules.new(anomaly_rule_params)
      if rule.save
        redirect_to application_environment_thresholds_path(application, environment), notice: "Anomaly rule added"
      else
        redirect_to application_environment_thresholds_path(application, environment), inertia: { errors: rule.errors }
      end
    end

    def update
      rule = environment.anomaly_rules.find(params[:id])
      rule.update(anomaly_rule_params)
      redirect_to application_environment_thresholds_path(application, environment), notice: "Anomaly rule updated"
    end

    def destroy
      environment.anomaly_rules.find(params[:id]).destroy
      redirect_to application_environment_thresholds_path(application, environment), notice: "Anomaly rule removed"
    end

    private

    def anomaly_rule_params
      params.permit(:target_kind, :target, :metric, :deviation, :window_minutes, :baseline_days, :enabled)
    end
    end
end
