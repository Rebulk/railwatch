# frozen_string_literal: true

module Lantern
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
      # prerequisites run, so their own #invoke/#execute calls see Lantern.execution
      # is not nil and just run plain, nesting inside the one command record instead
      # of each starting (and finishing) their own.
      def invoke(*args)
        super
      end

      private

      def run_as_command(command_suffix)
        return yield unless Lantern.enabled? && !SKIP.include?(name) && Lantern.execution.nil?
        return yield if vendor_excluded?

        exe = Lantern.start_execution(source: :command, sample_kind: :commands, preview: "rake #{name}")
        exe.enter_stage(:action)
        exit_code = 0
        begin
          yield
        rescue SystemExit => e
          exit_code = e.status
          raise
        rescue Exception => e # rubocop:disable Lint/RescueException
          exit_code = 1
          Lantern::Subscribers::Exceptions.capture(e, handled: false, severity: :error, source: "application.rake")
          raise
        ensure
          exe.finish_stages
          Lantern.finish_execution(:command,
            group: Record.group_hash(name),
            class: "Rake::Task",
            name: name,
            command: "rake #{name}#{command_suffix}",
            exit_code: exit_code.to_i.clamp(0, 255))
          Lantern.flush
        end
      end

      def args_suffix(args)
        args.respond_to?(:to_a) && args.to_a.any? ? "[#{args.to_a.join(',')}]" : ""
      end

      def vendor_excluded?
        !Lantern.config.capture_default_vendor_commands && Configuration::DEFAULT_VENDOR_COMMANDS.include?(name)
      end
    end
  end
end
