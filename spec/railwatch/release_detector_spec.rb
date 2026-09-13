# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe Railwatch::ReleaseDetector do
  let(:sha) { "0123456789abcdef0123456789abcdef01234567" }

  def detect(env = {}, &block)
    Dir.mktmpdir { |root| described_class.detect(project_root: root, env: env, &block) }
  end

  it "checks each deployment environment variable" do
    {
      "RAILWATCH_DEPLOY" => "release",
      "KAMAL_VERSION" => "kamal",
      "GIT_REV" => "git-rev",
      "GIT_SHA" => "git-sha",
      "SOURCE_VERSION" => "heroku-source",
      "HEROKU_SLUG_COMMIT" => "heroku-slug",
      "RENDER_GIT_COMMIT" => "render",
      "VERCEL_GIT_COMMIT_SHA" => "vercel",
      "CI_COMMIT_SHA" => "gitlab",
      "GITHUB_SHA" => "github"
    }.each do |key, value|
      expect(detect(key => value)).to eq(value)
    end
    expect(detect("FLY_IMAGE_REF" => "registry.fly.io/widgets:deployment-123")).to eq("deployment-123")
  end

  it "stops at the first environment hit" do
    env = described_class::ENV_KEYS.to_h { |key| [ key, key.downcase ] }
    source = nil

    expect(detect(env) { |found| source = found }).to eq("railwatch_deploy")
    expect(source).to eq("RAILWATCH_DEPLOY")
  end

  it "reads a Capistrano REVISION file" do
    Dir.mktmpdir do |root|
      File.write(File.join(root, "REVISION"), "#{sha}\n")

      expect(described_class.detect(project_root: root, env: {})).to eq(sha[0, 12])
    end
  end

  it "resolves a git HEAD through a loose ref" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, ".git/refs/heads"))
      File.write(File.join(root, ".git/HEAD"), "ref: refs/heads/main\n")
      File.write(File.join(root, ".git/refs/heads/main"), "#{sha}\n")

      expect(described_class.detect(project_root: root, env: {})).to eq(sha[0, 12])
    end
  end

  it "follows a git worktree's .git file to its gitdir and the repository's refs" do
    Dir.mktmpdir do |repo|
      FileUtils.mkdir_p(File.join(repo, ".git/refs/heads"))
      FileUtils.mkdir_p(File.join(repo, ".git/worktrees/feature"))
      File.write(File.join(repo, ".git/refs/heads/feature"), "#{sha}\n")
      File.write(File.join(repo, ".git/worktrees/feature/HEAD"), "ref: refs/heads/feature\n")
      File.write(File.join(repo, ".git/worktrees/feature/commondir"), "../..\n")
      Dir.mktmpdir do |root|
        File.write(File.join(root, ".git"), "gitdir: #{File.join(repo, ".git/worktrees/feature")}\n")

        expect(described_class.detect(project_root: root, env: {})).to eq(sha[0, 12])
      end
    end
  end

  it "reads a detached git HEAD" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, ".git"))
      File.write(File.join(root, ".git/HEAD"), "#{sha}\n")

      expect(described_class.detect(project_root: root, env: {})).to eq(sha[0, 12])
    end
  end

  it "resolves a git HEAD through packed-refs" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, ".git"))
      File.write(File.join(root, ".git/HEAD"), "ref: refs/heads/main\n")
      File.write(File.join(root, ".git/packed-refs"), "# pack-refs with: peeled\n#{sha} refs/heads/main\n")

      expect(described_class.detect(project_root: root, env: {})).to eq(sha[0, 12])
    end
  end

  it "truncates a sha from every source but preserves other release names" do
    expect(detect("RAILWATCH_DEPLOY" => sha)).to eq(sha[0, 12])
    expect(detect("RAILWATCH_DEPLOY" => "release-2026-09-06")).to eq("release-2026-09-06")
  end

  it "returns nil when no source contains a release" do
    expect(detect).to be_nil
  end

  it "returns nil for an unresolved or malformed git HEAD" do
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, ".git"))
      File.write(File.join(root, ".git/HEAD"), "ref: refs/heads/missing\n")

      expect(described_class.detect(project_root: root, env: {})).to be_nil
      File.write(File.join(root, ".git/HEAD"), "not-a-sha\n")
      expect(described_class.detect(project_root: root, env: {})).to be_nil
    end
  end
end
