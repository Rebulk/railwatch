# frozen_string_literal: true

require "active_support/json"

module Railwatch
  # Rails 8.1, up to and including 8.1.3.1, calls `JSON.parse` with a
  # positional options hash. json 3 made those options keyword arguments
  # (rails/rails#58784), so on that pair every signed cookie, every JSON
  # column, and this gem's own SQLite migrations raise ArgumentError. Ruby
  # 3.4.10 ships json 3.0.2 as a default gem, so a fresh machine meets it
  # without choosing to. The fix is merged on Rails' 8-1-stable branch and
  # unreleased as of 8.1.3.1.
  #
  # Detected by behaviour, not by version numbers: the pair is asked to
  # decode a document once. That way the check is right about combinations
  # nobody has enumerated (a patched Rails, a backport, a future json that
  # restores the old signature), and it goes quiet by itself the day the
  # host upgrades, with no release of this gem required.
  #
  # Railwatch does not pin `json` for the host. The breakage is the host
  # application's either way -- its sessions are already failing -- so the
  # gem reports it and the installer offers the pin, rather than quietly
  # constraining everybody's bundle for a bug that is not ours and is on its
  # way out.
  module JsonCompat
    PIN = %(gem "json", "< 3")
    ISSUE = "rails/rails#58784"

    module_function

    def broken?
      return @broken unless @broken.nil?

      @broken = begin
        ActiveSupport::JSON.decode("{}")
        false
      rescue ArgumentError
        true
      rescue StandardError
        # Anything else is not this bug.
        false
      end
    end

    # One line, usable from the installer, the doctor and a boot log.
    def advice
      "json #{json_version} cannot be decoded by Rails #{rails_version} (#{ISSUE}): signed cookies, JSON " \
        "columns and Railwatch's own migrations all raise ArgumentError on this pair. Add #{PIN} to your " \
        "Gemfile until Rails ships the fix, then remove it."
    end

    def json_version = defined?(::JSON::VERSION) ? ::JSON::VERSION : "unknown"
    def rails_version = defined?(::Rails) && ::Rails.respond_to?(:version) ? ::Rails.version : "unknown"

    # Test hook.
    def reset!
      @broken = nil
    end
  end
end
