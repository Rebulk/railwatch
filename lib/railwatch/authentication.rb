# frozen_string_literal: true

module Railwatch
  # `bin/rails railwatch:authentication:configure`: stores the embedded
  # dashboard's HTTP Basic credentials in the current environment's Rails
  # credentials, the same way Mission Control Jobs' authentication:configure
  # does. Asks for a user, generates the password, appends a `railwatch:`
  # entry to the credentials file the environment reads.
  module Authentication
    module_function

    def configure(io: $stdin, out: $stdout)
      unless credentials_accessible?
        out.puts "Rails credentials are not configured or the key is not available for `#{Rails.env}`. " \
                 "Set them up (`bin/rails credentials:help`) or set RAILWATCH_HTTP_BASIC_AUTH_USER and " \
                 "RAILWATCH_HTTP_BASIC_AUTH_PASSWORD in the environment instead."
        return false
      end
      if configured?
        out.puts "HTTP Basic authentication is already configured for `#{Rails.env}` (railwatch.http_basic_auth_user); " \
                 "edit it with `bin/rails credentials:edit#{env_flag}`."
        return false
      end

      out.print "Enter username for the Railwatch dashboard (#{Rails.env}): "
      username = io.gets.to_s.strip
      if username.empty?
        out.puts "No username given; nothing written."
        return false
      end
      password = SecureRandom.base58(48)
      credentials.write("#{credentials.read.to_s.chomp}\n\n#{entry(username, password)}")

      out.puts <<~DONE
        Stored in #{credentials.content_path.relative_path_from(Rails.root)} under `railwatch:`.

        The dashboard at /railwatch now asks for:
          user:     #{username}
          password: #{password}

        Edit later with `bin/rails credentials:edit#{env_flag}`. Restart the app to pick it up.
      DONE
      true
    end

    def credentials_accessible?
      credentials.read.present?
    rescue ActiveSupport::EncryptedFile::MissingKeyError, ActiveSupport::MessageEncryptor::InvalidMessage
      false
    end

    def configured?
      %i[http_basic_auth_user http_basic_auth_password].any? { |key| credentials.dig(:railwatch, key).present? }
    end

    # The file Rails.application.credentials reads for this environment:
    # config/credentials/<env>.yml.enc when that environment has one, else
    # config/credentials.yml.enc.
    def credentials
      config = Rails.application.config.credentials
      Rails.application.encrypted(config.content_path, key_path: config.key_path)
    end

    def env_flag
      Rails.root.join("config/credentials/#{Rails.env}.yml.enc").exist? ? " --environment #{Rails.env}" : ""
    end

    def entry(username, password)
      <<~YAML
        railwatch:
          http_basic_auth_user: #{username}
          http_basic_auth_password: #{password}
      YAML
    end
  end
end
