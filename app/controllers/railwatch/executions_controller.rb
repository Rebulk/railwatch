# frozen_string_literal: true

# Generic detail route for execution kinds that do not have a dedicated index
# yet (for example Action Cable channel actions), and for legacy child records
# whose execution_source was absent.
module Railwatch
    class ExecutionsController < DashboardController
    def show
      execution = telemetry { Telemetry::Execution.find_by!(execution_id: params[:id]) }
      render inertia: "executions/show", props: ExecutionPresenter.new(execution, environment).props
    end
    end
end
