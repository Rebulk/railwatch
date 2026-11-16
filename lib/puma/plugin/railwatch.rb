# frozen_string_literal: true

# `plugin :railwatch` ran the 0.x embedded writer, which 1.0 removed. Puma
# would refuse to boot with "Unknown plugin"; refuse with the migration.
raise "[railwatch] `plugin :railwatch` was removed in 1.0: delete it from config/puma.rb. " \
  "For the dashboard inside the app, add gem \"railwatch-server\" and `plugin :railwatch_server`. See " \
  "https://github.com/Rebulk/railwatch/blob/main/docs/getting-started.md#coming-from-0x-embedded-mode"
