# frozen_string_literal: true

module Nightrail
  module Patches
    # Rake tasks are Rails' commands. Each top-level task invocation is a
    # `command` execution; nested tasks (prerequisites) run inside it.
    module RakeTask
      SKIP = %w[environment].freeze

      def execute(args = nil)
        run_as_command(args_suffix(args)) { super }
      end

      # Rake dispatches a task's prerequisites via #invoke (Task#invoke_with_call_chain
      # calls invoke_prerequisites, which fully invokes -- and executes -- each
      # prerequisite, BEFORE calling the dependent task's own #execute). Patching
      # #invoke means the top-level command execution is already open by the time
      # prerequisites run, so their own #invoke/#execute calls see Nightrail.execution
      # is not nil and just run plain, nesting inside the one command record instead
      # of each starting (and finishing) their own.
      def invoke(*args)
        run_as_command(args.any? ? "[#{args.join(',')}]" : "") { super }
      end

      private

      # A vendor-excluded task (db:migrate, say) can internally call
      # `Rake::Task["db:_dump"].invoke` from its own action body -- an
      # implementation detail, not a prerequisite -- to run a task that isn't
      # itself vendor-excluded. With no execution open (the outer task never
      # started one), that inner call looks exactly like a fresh top-level
      # invocation and would ship its own unwanted command record. This flag
      # marks "we're inside a task we deliberately chose not to track," so
      # anything invoked underneath it is left untracked too.
      def run_as_command(command_suffix)
        return yield unless Nightrail.enabled? && !SKIP.include?(name) && Nightrail.execution.nil?
        return yield if Thread.current[:nightrail_vendor_excluded_rake]

        if vendor_excluded?
          Thread.current[:nightrail_vendor_excluded_rake] = true
          begin
            return yield
          ensure
            Thread.current[:nightrail_vendor_excluded_rake] = false
          end
        end

        exe = Nightrail.start_execution(source: :command, sample_kind: :commands, preview: "rake #{name}")
        exe.enter_stage(:action)
        exit_code = 0
        begin
          yield
        rescue SystemExit => e
          exit_code = e.status
          raise
        rescue SignalException => e
          # SIGTERM/SIGINT is how Kamal, systemd and Ctrl-C stop a long-running
          # task (a litestream replicator, a queue worker); it is a shutdown,
          # not a failure, so the command closes with the signal's exit code
          # and no exception is reported.
          exit_code = 128 + (e.signo || 0)
          raise
        rescue Exception => e # rubocop:disable Lint/RescueException
          exit_code = 1
          Nightrail::Subscribers::Exceptions.capture(e, handled: false, severity: :error, source: "application.rake")
          raise
        ensure
          exe.finish_stages
          Nightrail.finish_execution(:command,
            group: Record.group_hash(name),
            class: "Rake::Task",
            name: name,
            command: "rake #{name}#{command_suffix}",
            exit_code: exit_code.to_i.clamp(0, 255))
          Nightrail.flush
        end
      end

      def args_suffix(args)
        args.respond_to?(:to_a) && args.to_a.any? ? "[#{args.to_a.join(',')}]" : ""
      end

      def vendor_excluded?
        !Nightrail.config.capture_default_vendor_commands && Configuration::DEFAULT_VENDOR_COMMANDS.include?(name)
      end
    end
  end
end
