# frozen_string_literal: true

require "lantern/patches/net_http"
require "lantern/patches/rake_task"
require "lantern/patches/runner_command"
require "lantern/patches/inertia"

module Lantern
  module Patches
    module_function

    def install!
      ::Net::HTTP.prepend(NetHttp) unless ::Net::HTTP.ancestors.include?(NetHttp)
      require "rake"
      ::Rake::Task.prepend(RakeTask) unless ::Rake::Task.ancestors.include?(RakeTask)
      install_runner_command!
      Inertia.install!
    end

    # rails/commands/runner/runner_command isn't always loaded (e.g. under a
    # plain rake or server boot), so this is best-effort. "rails/command"
    # must be required first -- it declares the autoload for Base that
    # RunnerCommand subclasses, and isn't guaranteed loaded yet this early.
    def install_runner_command!
      require "rails/command"
      require "rails/commands/runner/runner_command"
      unless ::Rails::Command::RunnerCommand.ancestors.include?(RunnerCommand)
        ::Rails::Command::RunnerCommand.prepend(RunnerCommand)
      end
    rescue LoadError, StandardError
      nil
    end
  end
end
