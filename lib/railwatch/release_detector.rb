# frozen_string_literal: true

module Railwatch
  # Finds the release already exposed by a deploy platform or checkout without
  # spawning git during application boot. SHA releases are shortened so every
  # source produces the same compact deploy value.
  module ReleaseDetector
    ENV_KEYS = %w[
      RAILWATCH_DEPLOY KAMAL_VERSION GIT_REV GIT_SHA SOURCE_VERSION
      HEROKU_SLUG_COMMIT RENDER_GIT_COMMIT FLY_IMAGE_REF
      VERCEL_GIT_COMMIT_SHA CI_COMMIT_SHA GITHUB_SHA
    ].freeze
    SHA = /\A[0-9a-f]{40}\z/i

    module_function

    def detect(project_root:, env: ENV)
      ENV_KEYS.each do |key|
        value = env[key].to_s.strip
        next if value.empty?

        value = value.rpartition(":").last if key == "FLY_IMAGE_REF"
        next if value.empty?

        yield key if block_given?
        return normalize(value)
      end

      revision = read(File.join(project_root.to_s, "REVISION"))
      if revision && !revision.strip.empty?
        yield "REVISION" if block_given?
        return normalize(revision.strip)
      end

      sha = git_sha(File.join(project_root.to_s, ".git"))
      if sha
        yield "git" if block_given?
        normalize(sha)
      end
    end

    def git_sha(git_dir)
      git_dir = resolve_gitdir(git_dir)
      head = read(File.join(git_dir, "HEAD"))&.strip
      return head if SHA.match?(head.to_s)
      return unless head&.start_with?("ref: refs/")

      ref = head.delete_prefix("ref: ")
      return if ref.include?("..") || ref.include?("\\") || ref.end_with?("/")

      # A worktree's gitdir holds HEAD but its refs and packed-refs live in
      # the repository it was created from, named by its commondir file.
      refs_dir = read(File.join(git_dir, "commondir"))&.strip
      refs_dir = refs_dir ? File.expand_path(refs_dir, git_dir) : git_dir
      loose = read(File.join(refs_dir, ref))&.strip
      return loose if SHA.match?(loose.to_s)

      packed_ref(refs_dir, ref)
    end
    private_class_method :git_sha

    # A worktree's .git is a file naming its gitdir ("gitdir: ...").
    def resolve_gitdir(git_dir)
      return git_dir unless File.file?(git_dir)

      pointer = read(git_dir).to_s.strip
      return git_dir unless pointer.start_with?("gitdir: ")

      File.expand_path(pointer.delete_prefix("gitdir: "), File.dirname(git_dir))
    end
    private_class_method :resolve_gitdir

    def packed_ref(git_dir, ref)
      packed = read(File.join(git_dir, "packed-refs"))
      return unless packed

      packed.each_line do |line|
        sha, name = line.strip.split(" ", 2)
        return sha if name == ref && SHA.match?(sha.to_s)
      end
      nil
    end
    private_class_method :packed_ref

    def read(path)
      File.read(path)
    rescue SystemCallError, IOError
      nil
    end
    private_class_method :read

    def normalize(value)
      SHA.match?(value) ? value[0, 12] : value
    end
    private_class_method :normalize
  end
end
