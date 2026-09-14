# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Railwatch::SecretSafety do
  it "reports a token only by prefix and length" do
    expect(described_class.token_preview("rw_super_secret_value")).to eq("rw_sup... (21 chars)")
  end

  it "distinguishes ignored, tracked, and ordinary dotenv paths" do
    Dir.mktmpdir do |root|
      system("git", "init", "-q", root)
      File.write(File.join(root, ".gitignore"), ".env\n")

      expect(described_class.git_ignored?(".env", root: root)).to be(true)
      expect(described_class.git_tracked?(".env", root: root)).to be(false)

      File.write(File.join(root, ".env"), "RAILWATCH_TOKEN=rw_a_real_secret\n")
      system("git", "-C", root, "add", "-f", ".env")

      expect(described_class.git_tracked?(".env", root: root)).to be(true)
    end
  end

  it "returns only tracked paths containing plaintext Railwatch tokens" do
    Dir.mktmpdir do |root|
      system("git", "init", "-q", root)
      FileUtils.mkdir_p(File.join(root, "config/initializers"))
      File.write(File.join(root, ".env"), "RAILWATCH_TOKEN=rw_not_committed\n")
      File.write(File.join(root, "config/initializers/railwatch.rb"), 'c.token = "rw_committed_secret"\n')
      File.write(File.join(root, "config/deploy.yml"), "RAILWATCH_TOKEN: lt_minted_before_0_1_1\n")
      system("git", "-C", root, "add", "config/initializers/railwatch.rb", "config/deploy.yml")

      expect(described_class.tracked_plaintext_token_files(root: root))
        .to eq([ "config/deploy.yml", "config/initializers/railwatch.rb" ])
    end
  end
end
