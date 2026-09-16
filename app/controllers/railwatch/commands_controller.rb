# frozen_string_literal: true

module Railwatch
    class CommandsController < DashboardController
    def index
      rows = telemetry { Telemetry::Execution.commands.between(*window_range).recent.limit(200).to_a }
      render inertia: { commands: grouped("command", limit: 100),
                        runs: rows.map { |r| { execution_id: r.execution_id, name: r.name, exit_code: r.status, duration: r.duration_ms.round(1), occurred_at: r.occurred_at, server: r.server, exception_preview: r.exception_preview } } }
    end

    def show
      exe = telemetry { Telemetry::Execution.find_by!(execution_id: params[:id]) }
      render inertia: "executions/show", props: ExecutionPresenter.new(exe, environment).props
    end
    end
end
