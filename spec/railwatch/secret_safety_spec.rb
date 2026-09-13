# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Railwatch::SecretSafety do
  it "reports a token only by prefix and length" do
    expect(described_class.token_preview("lt_super_secret_value")).to eq("lt_sup... (21 chars)")
  end

  it "distinguishes ignored, tracked, and ordinary dotenv paths" do
    Dir.mktmpdir do |root|
      system("git", "init", "-q", root)
      File.write(File.join(root, ".gitignore"), ".env\n")

      expect(described_class.git_ignored?(".env", root: root)).to be(true)
      expect(described_class.git_tracked?(".env", root: root)).to be(false)

      File.write(File.join(root, ".env"), "RAILWATCH_TOKEN=lt_a_real_secret\n")
      system("git", "-C", root, "add", "-f", ".env")

      expect(described_class.git_tracked?(".env", root: root)).to be(true)
    end
  end

  it "returns only tracked paths containing plaintext Railwatch tokens" do
    Dir.mktmpdir do |root|
      system("git", "init", "-q", root)
      FileUtils.mkdir_p(File.join(root, "config/initializers"))
      File.write(File.join(root, ".env"), "RAILWATCH_TOKEN=lt_not_committed\n")
      File.write(File.join(root, "config/initializers/railwatch.rb"), 'c.token = "lt_committed_secret"\n')
      system("git", "-C", root, "add", "config/initializers/railwatch.rb")

      expect(described_class.tracked_plaintext_token_files(root: root))
        .to eq([ "config/initializers/railwatch.rb" ])
    end
  end
end
