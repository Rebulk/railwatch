# frozen_string_literal: true

module Railwatch
    class ThresholdsController < DashboardController
    def index
      render inertia: { thresholds: environment.thresholds.order(:target_kind, :target).map { |t| t.slice(:id, :target_kind, :target, :metric, :limit, :window_minutes).merge(description: t.description) },
                        routes: telemetry { Telemetry::Rollup.for_type("request").where("bucket > ?", 7.days.ago).distinct.pluck(:name).sort },
                        jobs: telemetry { Telemetry::Rollup.for_type("job_attempt").where("bucket > ?", 7.days.ago).distinct.pluck(:name).sort },
                        kinds: Threshold::TARGET_KINDS, metrics: Threshold::METRICS,
                        anomaly_rules: environment.anomaly_rules.order(:target_kind, :target).map { |r| r.slice(:id, :target_kind, :target, :metric, :deviation, :window_minutes, :baseline_days, :enabled, :last_fired_at).merge(description: r.description) },
                        anomaly_target_kinds: AnomalyRule::TARGET_KINDS, anomaly_metrics: AnomalyRule::METRICS }
    end

    def create
      threshold = environment.thresholds.new(threshold_params)
      if threshold.save
        redirect_to application_environment_thresholds_path(application, environment), notice: "Threshold added"
      else
        redirect_to application_environment_thresholds_path(application, environment), inertia: { errors: threshold.errors }
      end
    end

    def update
      threshold = environment.thresholds.find(params[:id])
      threshold.update(threshold_params)
      redirect_to application_environment_thresholds_path(application, environment), notice: "Threshold updated"
    end

    def destroy
      environment.thresholds.find(params[:id]).destroy
      redirect_to application_environment_thresholds_path(application, environment), notice: "Threshold removed"
    end

    private

    def threshold_params
      params.permit(:target_kind, :target, :metric, :limit, :window_minutes)
    end
    end
end
