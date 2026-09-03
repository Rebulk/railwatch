require_relative "lib/lantern/version"

Gem::Specification.new do |spec|
  spec.name        = "lantern"
  spec.version     = Lantern::VERSION
  spec.authors     = [ "Cole Robertson" ]
  spec.email       = [ "cole@rebulk.com" ]
  spec.homepage    = "https://github.com/cole-robertson/lantern"
  spec.summary     = "First-class monitoring for Rails applications."
  spec.description = "Lantern instruments a Rails app end to end (requests, jobs, queries, exceptions, cache, mail, broadcasts, outgoing HTTP, logs) and ships linked events to Lantern Cloud."
  spec.license     = "MIT"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "#{spec.homepage}/blob/main/README.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.required_ruby_version = ">= 3.4"

  spec.files = Dir.chdir(File.expand_path(__dir__)) do
    # docs/, llms.txt and AGENTS.md ship with the gem: `bundle open lantern`
    # and any coding agent looking at the installed gem get the same
    # documentation as the repository.
    Dir["{app,config,lib,docs}/**/*", "MIT-LICENSE", "Rakefile", "README.md", "CHANGELOG.md", "llms.txt", "AGENTS.md"]
  end

  spec.add_dependency "rails", ">= 8.1"
end
