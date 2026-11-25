# frozen_string_literal: true

require "yaml"

module Railwatch
  # `bin/rails railwatch:authentication:configure`: stores the HTTP Basic
  # credentials railwatch-sidecar's dashboard proxy checks in the current
  # environment's Rails credentials, the same way Mission Control Jobs'
  # authentication:configure does. Asks for a user, generates the password,
  # appends a `railwatch:` entry to the credentials file the environment
  # reads.
  module Authentication
    # What a failed configure raises instead of the error it hit.
    class Error < StandardError; end

    module_function

    # This task holds the environment's DECRYPTED credentials: as a String
    # inside ActiveSupport::EncryptedFile#write (its `contents`), inside
    # Rails' and Psych's parsers, and as the Hash below. Any of them that
    # raises -- an unwritable config directory, a full disk, YAML that does
    # not parse -- raises in a frame whose locals hold that plaintext, and
    # the task runs under the rake patch, which reports the unhandled error
    # with those locals when capture_exception_locals is on (the first 200
    # characters of the document: all of a generated secret_key_base). The
    # parameter filter cannot help, since the local is a String under a
    # neutral name. So whatever fails is replaced by an Error raised from
    # #fail_without_document, whose only local is the message, and with no
    # cause, so the original (which carries the snapshot) is not kept. The
    # task still fails, with the system error (and its path) in the message;
    # any other error is named by its class only, since a parser error can
    # quote the document.
    def configure(io: $stdin, out: $stdout)
      configure_credentials(io, out)
    rescue StandardError => e
      detail = e.is_a?(SystemCallError) ? "#{e.class}: #{e.message}" : e.class.name
      fail_without_document("Could not update the Rails credentials for `#{Rails.env}` (#{detail}).")
    end

    def fail_without_document(message)
      raise Error, message, cause: nil
    end

    def configure_credentials(io, out)
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
      # Merge, never append. A second top-level `railwatch:` mapping would
      # win in Psych and silently hide whatever the first one held, and a
      # username with YAML syntax in it would reshape the file; round-tripping
      # through the parser and to_yaml quotes it correctly.
      merged = (YAML.safe_load(credentials.read.to_s, permitted_classes: [ Symbol ], aliases: true) || {})
      unless merged.is_a?(Hash)
        out.puts "#{credentials.content_path} does not contain a YAML mapping; edit it by hand."
        return false
      end
      merged["railwatch"] = (merged["railwatch"].is_a?(Hash) ? merged["railwatch"] : {})
        .merge("http_basic_auth_user" => username, "http_basic_auth_password" => password)
      credentials.write(merged.to_yaml)

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

    # Both halves, so a file holding only one of them is repaired rather than
    # refused (which would leave the dashboard closed with no way forward).
    def configured?
      %i[http_basic_auth_user http_basic_auth_password].all? { |key| credentials.dig(:railwatch, key).present? }
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
  end
end
