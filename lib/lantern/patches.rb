# frozen_string_literal: true

require "lantern/patches/net_http"
require "lantern/patches/rake_task"
require "lantern/patches/runner_command"
require "lantern/patches/inertia"

module Lantern
  module Patches
    module_function

    # The patches every process needs. Rake and the runner command are
    # installed from the engine's rake_tasks and runner hooks instead, which
    # fire only in a process that is actually about to run one: requiring
    # rake and railties' runner command in every web and worker boot cost
    # about 170 ms for code those processes never call.
    def install!
      ::Net::HTTP.prepend(NetHttp) unless ::Net::HTTP.ancestors.include?(NetHttp)
      Inertia.install!
    end

    # From Rails::Engine#load_tasks, which has already required rake.
    def install_rake_task!
      ::Rake::Task.prepend(RakeTask) unless ::Rake::Task.ancestors.include?(RakeTask)
    end

    # From Rails::Application#load_runner, which RunnerCommand#perform calls
    # after boot_application! -- so the class is loaded by the time this
    # runs, and the prepend is in place before conditional_executor.
    def install_runner_command!
      require "rails/command"
      require "rails/commands/runner/runner_command"
      unless ::Rails::Command::RunnerCommand.ancestors.include?(RunnerCommand)
        ::Rails::Command::RunnerCommand.prepend(RunnerCommand)
      end
    rescue LoadError, StandardError => e
      # A railties rename would land here; say so rather than leaving every
      # deployed `rails runner` script silently untraced.
      Lantern.debug { "runner command patch not installed: #{e.class}: #{e.message}" }
      nil
    end
  end
end
