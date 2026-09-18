# frozen_string_literal: true

module Railwatch
  # Emits the dashboard's script and stylesheet tags from the manifest Vite
  # wrote at gem build time. The gem ships the built bundle under
  # public/railwatch, so a host app needs no Node toolchain and no asset
  # pipeline integration: the engine serves those files itself and this
  # helper does the little that rails_vite's vite_tags would have done.
  module AssetsHelper
    MANIFEST = Railwatch::Engine.root.join("public/railwatch/manifest.json")
    ASSET_PREFIX = "/railwatch/assets"

    def railwatch_asset_tags(nonce: nil)
      manifest = railwatch_manifest
      tags = []
      preloaded = Set.new
      %w[app/frontend/entrypoints/application.css app/frontend/entrypoints/inertia.tsx].each do |entry|
        info = manifest.fetch(entry)
        Array(info["imports"]).each do |key|
          file = manifest.fetch(key)["file"]
          next unless preloaded.add?(file)
          tags << tag.link(rel: "modulepreload", href: "#{ASSET_PREFIX}/#{file}", nonce: nonce)
        end
        tags << if info["file"].end_with?(".css")
          tag.link(rel: "stylesheet", href: "#{ASSET_PREFIX}/#{info['file']}", nonce: nonce)
        else
          tag.script(src: "#{ASSET_PREFIX}/#{info['file']}", type: "module", nonce: nonce)
        end
        Array(info["css"]).each { |css| tags << tag.link(rel: "stylesheet", href: "#{ASSET_PREFIX}/#{css}", nonce: nonce) }
      end
      safe_join(tags, "\n")
    end

    def railwatch_font_preloads
      safe_join(railwatch_manifest.select { |k, _| k.end_with?(".woff2") && k.include?("Roboto") }.map { |_, v|
        tag.link(rel: "preload", href: "#{ASSET_PREFIX}/#{v['file']}", as: "font", type: "font/woff2", crossorigin: "anonymous")
      }, "\n")
    end

    # The bundle digest doubles as the Inertia asset version: a gem upgrade
    # changes it and every open tab does a full reload on its next visit.
    def self.digest
      @digest ||= Digest::SHA256.file(MANIFEST).hexdigest[0, 16]
    end

    private

    def railwatch_manifest
      @railwatch_manifest ||= JSON.parse(File.read(MANIFEST))
    end
  end
end
