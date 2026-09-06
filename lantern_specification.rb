# frozen_string_literal: true

require_relative "lib/lantern/version"

module Lantern
  module Packaging
    PUBLIC_NAME = "lantern-observability"

    module_function

    def specification(name: PUBLIC_NAME)
      Gem::Specification.new do |spec|
        spec.name        = name
        spec.version     = Lantern::VERSION
        spec.authors     = [ "Cole Robertson" ]
        spec.email       = [ "cole@rebulk.com" ]
        spec.homepage    = "https://lantern.rebulk.com"
        spec.summary     = "First-class monitoring for Rails applications."
        spec.description = "Lantern instruments a Rails app end to end (requests, jobs, queries, exceptions, cache, mail, broadcasts, outgoing HTTP, logs) and ships linked events to Lantern Cloud."
        spec.license     = "MIT"

        spec.metadata["homepage_uri"] = spec.homepage
        spec.metadata["source_code_uri"] = "https://github.com/Rebulk/lantern"
        spec.metadata["changelog_uri"] = "https://github.com/Rebulk/lantern/blob/main/CHANGELOG.md"
        spec.metadata["documentation_uri"] = "https://github.com/Rebulk/lantern/blob/main/README.md"
        spec.metadata["rubygems_mfa_required"] = "true"

        spec.required_ruby_version = ">= 3.4"

        spec.files = Dir.chdir(__dir__) do
          # Installed gems carry the runtime and public reference material,
          # while repository-only tests, scripts, and release machinery stay
          # out of customer applications.
          Dir["{app,config,lib,docs}/**/*", "README.md", "CHANGELOG.md", "MIT-LICENSE", "llms.txt", "AGENTS.md"]
            .select { |path| File.file?(path) }
        end

        spec.add_dependency "rails", ">= 8.1", "< 9"
        # Used for profile stacks and attachments. A bundled gem since Ruby
        # 3.4, so it must be declared rather than assumed from stdlib.
        spec.add_dependency "base64", "~> 0.2"
      end
    end
  end
end
