# frozen_string_literal: true

module Lantern
  module Patches
    # `bin/rails runner` is a command execution, same as a rake task, but
    # Rails::Command::RunnerCommand#perform isn't a Rake::Task so it needs its
    # own prepend.
    module RunnerCommand
      def perform(code_or_file = nil, *command_argv)
        return super unless Lantern.enabled? && Lantern.execution.nil?

        preview = code_or_file.to_s[0, 200]
        exe = Lantern.start_execution(source: :command, sample_kind: :commands, preview: "rails runner #{preview}")
        exe.enter_stage(:action)
        exit_code = 0
        begin
          super
        rescue SystemExit => e
          exit_code = e.status
          raise
        rescue SignalException => e
          # A signal ends the runner by design (see the rake patch); not reported.
          exit_code = 128 + (e.signo || 0)
          raise
        rescue Exception => e # rubocop:disable Lint/RescueException
          exit_code = 1
          Lantern::Subscribers::Exceptions.capture(e, handled: false, severity: :error, source: "application.runner")
          raise
        ensure
          exe.finish_stages
          Lantern.finish_execution(:command,
            group: Record.group_hash("runner"),
            class: "Rails::Command::RunnerCommand",
            name: "runner",
            command: "rails runner #{preview}",
            exit_code: exit_code.to_i.clamp(0, 255))
          Lantern.flush
        end
      end
    end
  end
end
