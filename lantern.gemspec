require_relative "lantern_specification"

# Transitional Git-source package. Lantern Cloud and existing source consumers
# request `gem "lantern", github: "Rebulk/lantern"`; keeping this spec lets
# Bundler resolve those deployments while the public RubyGems distribution uses
# the unclaimed `lantern-observability` name. Do not publish this legacy spec.
Lantern::Packaging.specification(name: "lantern")
