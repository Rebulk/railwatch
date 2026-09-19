# frozen_string_literal: true

require "spec_helper"
require "open3"
require "tmpdir"

RSpec.describe "an embedded app's rake process" do
  # The token is what makes this reachable: it is enough for Railwatch to be
  # enabled before config/initializers has said the app is embedded, so the
  # reporter picks HTTP and keeps it. An embedded install that still has the
  # token it used before moving off the hosted receiver is in exactly this
  # position, and so is every hybrid install, since export needs one.
  it "reports into the app's own database rather than over HTTP" do
    Dir.mktmpdir("railwatch-rake-boot") do |root|
      FileUtils.mkdir_p("#{root}/config/initializers")
      File.write("#{root}/config/database.yml", "test:\n  adapter: sqlite3\n  database: ':memory:'\n")
      File.write("#{root}/config/initializers/railwatch.rb", <<~RUBY)
        Railwatch.configure do |config|
          config.transport = :local
        end
      RUBY

      output, status = Open3.capture2e(
        { "RAILS_ENV" => "test", "RAKE_BOOT_ROOT" => root,
          "RAILWATCH_TOKEN" => "rake-boot-token", "RAILWATCH_INGEST_URL" => "http://127.0.0.1:19474" },
        Gem.ruby, File.expand_path("../../fixtures/rake_boot.rb", __dir__))

      expect(status.success?).to be(true), output
      expect(output).to include("RAKE_BOOT_TRANSPORT_OK")
    end
  end
end
