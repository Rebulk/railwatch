# frozen_string_literal: true

require_relative "lib/railwatch/version"

module Railwatch
  module Packaging
    PUBLIC_NAME = "railwatch"

    module_function

    def specification(name: PUBLIC_NAME)
      Gem::Specification.new do |spec|
        spec.name        = name
        spec.version     = Railwatch::VERSION
        spec.authors     = [ "Cole Robertson" ]
        spec.email       = [ "cole@rebulk.com" ]
        spec.homepage    = "https://railwatch.rebulk.com"
        spec.summary     = "First-class monitoring for Rails applications."
        spec.description = "Railwatch instruments a Rails app end to end (requests, jobs, queries, exceptions, cache, mail, broadcasts, outgoing HTTP, logs) and ships linked events to Railwatch Cloud."
        spec.license     = "MIT"

        spec.metadata["homepage_uri"] = spec.homepage
        source_repository = "https://github.com/Rebulk/railwatch"
        spec.metadata["source_code_uri"] = source_repository
        spec.metadata["changelog_uri"] = "#{source_repository}/blob/main/CHANGELOG.md"
        spec.metadata["documentation_uri"] = "#{source_repository}/blob/main/README.md"
        spec.metadata["rubygems_mfa_required"] = "true"

        spec.required_ruby_version = ">= 3.4"

        spec.files = Dir.chdir(__dir__) do
          # Installed gems carry the runtime and public reference material,
          # while repository-only tests, scripts, and release machinery stay
          # out of customer applications.
          Dir["{app,config,lib,docs,public}/**/*", "README.md", "CHANGELOG.md", "MIT-LICENSE", "llms.txt", "AGENTS.md"]
            .select { |path| File.file?(path) }
        end

        spec.add_dependency "rails", ">= 8.1", "< 9"
        # Used for profile stacks and attachments. A bundled gem since Ruby
        # 3.4, so it must be declared rather than assumed from stdlib.
        spec.add_dependency "base64", "~> 0.2"
        spec.add_dependency "inertia_rails", "~> 3.21"
      end
    end
  end
end
