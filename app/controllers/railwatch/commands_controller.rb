# frozen_string_literal: true

module Railwatch
    class CommandsController < DashboardController
    def index
      rows = telemetry { Telemetry::Execution.commands.between(*window_range).recent.limit(200).to_a }
      render inertia: { commands: grouped("command", limit: 100),
                        runs: rows.map(&:as_row) }
    end

    def show
      exe = telemetry { Telemetry::Execution.find_by!(execution_id: params[:id]) }
      render inertia: "executions/show", props: ExecutionPresenter.new(exe, environment).props
    end
    end
end
