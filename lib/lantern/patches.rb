# frozen_string_literal: true

require "lantern/patches/net_http"
require "lantern/patches/rake_task"
require "lantern/patches/inertia"

module Lantern
  module Patches
    module_function

    def install!
      ::Net::HTTP.prepend(NetHttp) unless ::Net::HTTP.ancestors.include?(NetHttp)
      require "rake"
      ::Rake::Task.prepend(RakeTask) unless ::Rake::Task.ancestors.include?(RakeTask)
      Inertia.install!
    end
  end
end
