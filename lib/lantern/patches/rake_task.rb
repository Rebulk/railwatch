# frozen_string_literal: true

module Lantern
  module Patches
    # Rake tasks are Rails' commands. Each top-level task invocation is a
    # `command` execution; nested tasks (prerequisites) run inside it.
    module RakeTask
      SKIP = %w[environment].freeze

      def execute(args = nil)
        return super unless Lantern.enabled? && !SKIP.include?(name) && Lantern.execution.nil?
        return super if vendor_excluded?

        exe = Lantern.start_execution(source: :command, sample_kind: :commands, preview: "rake #{name}")
        exe.enter_stage(:action)
        exit_code = 0
        begin
          super
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
            command: "rake #{name}#{args.respond_to?(:to_a) && args.to_a.any? ? "[#{args.to_a.join(',')}]" : ''}",
            exit_code: exit_code.to_i.clamp(0, 255))
          Lantern.flush
        end
      end

      private

      def vendor_excluded?
        !Lantern.config.capture_default_vendor_commands && Configuration::DEFAULT_VENDOR_COMMANDS.include?(name)
      end
    end
  end
end
