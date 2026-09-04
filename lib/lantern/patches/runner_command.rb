# frozen_string_literal: true

module Lantern
  module Patches
    # `bin/rails runner` is a command execution, same as a rake task, but
    # Rails::Command::RunnerCommand#perform isn't a Rake::Task so it needs its
    # own prepend.
    #
    # Two very different things arrive here, and only one of them is an issue.
    # A DEPLOYED script -- `rails runner script/nightly.rb` from cron, a
    # release step, a container entrypoint -- must report: a nightly job that
    # starts dying is exactly what monitoring is for. An INTERACTIVE run is an
    # engineer at a shell typing at production, and their typo (a misspelled
    # attribute, a tenant slug that does not exist, an `unless ... next` that
    # does not parse) is the ops equivalent of a shell error, not a bug in the
    # app. Under Sentry those typos opened four of fifteen unresolved issues
    # in this app and woke an automated responder each time.
    #
    # The line is WHERE THE CODE CAME FROM, which railties makes plain -- its
    # #perform reaches the operator's code through three call sites:
    #
    #   rails runner -            -> eval($stdin.read, TOPLEVEL_BINDING, "stdin")
    #   rails runner 'Some.code'  -> eval(code_or_file, TOPLEVEL_BINDING, __FILE__, __LINE__)
    #   rails runner script.rb    -> Kernel.load(expanded_file_path)
    #
    # so the argument alone answers it: `-` is piped, anything that is not a
    # `.rb` path was typed inline, and a `.rb` path is a file -- deployed
    # unless it sits in a scratch directory (config.interactive_runner_paths),
    # because nothing an app deploys lives in /tmp.
    #
    # An interactive run still opens its execution and still ships the
    # `command` record (with exit_code, and `interactive: true`) -- you can
    # see that someone ran it, and what it cost. Only the exception is
    # withheld, and that is done by flagging the execution rather than by
    # skipping the capture below: the Rails executor hands the error to
    # Rails.error inside `super`, so Subscribers::Exceptions has already seen
    # it by the time this rescue runs.
    module RunnerCommand
      def perform(code_or_file = nil, *command_argv)
        return super unless Lantern.enabled? && Lantern.execution.nil?

        preview = code_or_file.to_s[0, 200]
        interactive = RunnerCommand.interactive?(code_or_file)
        exe = Lantern.start_execution(source: :command, sample_kind: :commands, preview: "rails runner #{preview}")
        exe.interactive = true if interactive
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
          fields = {
            group: Record.group_hash("runner"),
            class: "Rails::Command::RunnerCommand",
            name: "runner",
            command: "rails runner #{preview}",
            exit_code: exit_code.to_i.clamp(0, 255)
          }
          fields[:interactive] = true if interactive
          Lantern.finish_execution(:command, **fields)
          Lantern.flush
        end
      end

      # Typed or piped by a human, rather than loaded from a deployed file.
      def self.interactive?(code_or_file)
        argument = code_or_file.to_s
        # "-" (stdin), "" (railties prints help and exits), and inline code.
        return true unless argument.end_with?(".rb")

        scratch?(argument)
      end

      # Expanded so a relative path is judged by where it actually resolves.
      # An argument File.expand_path refuses (a "~nobody/x.rb") is matched
      # as-is rather than assumed interactive: when in doubt, report.
      def self.scratch?(argument)
        path = begin
          File.expand_path(argument)
        rescue StandardError
          argument
        end
        Lantern.config.interactive_runner_paths.any? { |directory| path.start_with?(directory) }
      end
    end
  end
end
