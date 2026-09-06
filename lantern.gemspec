# frozen_string_literal: true

require_relative "lantern_specification"

# Existing Git-source consumers resolve this spec by its legacy name. The
# RubyGems release uses Packaging::PUBLIC_NAME; do not publish this spec.
Lantern::Packaging.specification(name: "lantern")
