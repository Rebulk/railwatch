# frozen_string_literal: true

require_relative "lib/lantern/version"

module Lantern
  module Packaging
    module_function

    def specification(name:)
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
          # docs/, llms.txt and AGENTS.md ship with the gem: `bundle open
          # lantern-observability` gives people and coding agents the same
          # documentation as the repository.
          Dir["{app,config,lib,docs}/**/*", "MIT-LICENSE", "Rakefile", "README.md", "CHANGELOG.md", "llms.txt", "AGENTS.md"]
            .select { |path| File.file?(path) }
        end

        spec.add_dependency "rails", ">= 8.1", "< 9"
      end
    end
  end
end
