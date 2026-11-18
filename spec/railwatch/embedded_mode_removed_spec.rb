# frozen_string_literal: true

require "spec_helper"

# 1.0 removed embedded mode. An app upgrading from 0.x still has its
# settings, so each one fails with the migration rather than NoMethodError.
RSpec.describe "Embedded mode settings removed in 1.0" do
  Railwatch::Configuration::EMBEDDED_MODE_SETTINGS.each do |name|
    it "explains the migration when #{name} is assigned" do
      config = Railwatch::Configuration.new
      expect { config.public_send(:"#{name}=", :local) }
        .to raise_error(Railwatch::Configuration::RemovedSetting, /`#{name}` was removed.*railwatch-sidecar.*coming-from-0x-embedded-mode/)
    end
  end

  it "is still a NoMethodError for code that rescues one" do
    expect(Railwatch::Configuration::RemovedSetting.ancestors).to include(NoMethodError)
  end

  it "names RAILWATCH_TRANSPORT when it is still set" do
    original = ENV["RAILWATCH_TRANSPORT"]
    ENV["RAILWATCH_TRANSPORT"] = "local"
    expect(Railwatch::Configuration.new.embedded_mode_env).to eq("RAILWATCH_TRANSPORT")
    ENV.delete("RAILWATCH_TRANSPORT")
    expect(Railwatch::Configuration.new.embedded_mode_env).to be_nil
  ensure
    original.nil? ? ENV.delete("RAILWATCH_TRANSPORT") : ENV["RAILWATCH_TRANSPORT"] = original
  end

  it "refuses `plugin :railwatch` with the migration" do
    expect { load File.expand_path("../../lib/puma/plugin/railwatch.rb", __dir__) }
      .to raise_error(RuntimeError, /plugin :railwatch` was removed.*railwatch_sidecar/)
  end
end
