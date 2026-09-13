# frozen_string_literal: true

module Railwatch
  # `bin/rails console` is a person at a prompt, not a server. sentry-rails
  # never hooked the console at all, and that was right: an engineer poking at
  # production types typos, and a typo is not an issue. Railwatch subscribes to
  # far more than Sentry did (every query, every log line, `Rails.error`), and
  # it starts reporter/health/session threads at boot -- none of which belong
  # behind an IRB prompt someone leaves open for an hour.
  #
  # So a console process goes quiet: nothing is captured, no thread is
  # started, and no `process`/`health` record is sent. Opt back in with
  # `config.capture_console = true` (or RAILWATCH_CAPTURE_CONSOLE=1) for the
  # rare "trace what I'm about to do in here" session.
  #
  # A `rails runner` script is NOT this: it is a deployed execution and keeps
  # reporting -- see Railwatch::Patches::RunnerCommand for where that line is.
  module Console
    module_function

    # railties defines Rails::Console when it loads the console command, which
    # happens before the application boots, so this is already true by the
    # time the engine's initializers run.
    def detected?
      !!defined?(::Rails::Console)
    end

    def quiet?
      detected? && !Railwatch.config.capture_console
    end

    # Idempotent, and the whole of quiet mode: every record path, the
    # subscriber install, the after_initialize `process` record, and the
    # reporter/health/sessions threads are already gated on Railwatch.enabled?.
    # Returns whether this call is what silenced the process.
    def silence!
      return false unless quiet? && Railwatch.config.enabled

      Railwatch.debug { "console detected -- capturing nothing in this process (set config.capture_console = true, or RAILWATCH_CAPTURE_CONSOLE=1, to capture a console session)" }
      Railwatch.config.enabled = false
      # No-ops unless a console got here after boot (the railtie's `console`
      # block) with the threads already running.
      Health.stop!
      Sessions.stop!
      true
    end
  end
end
