# frozen_string_literal: true

namespace :lantern do
  desc "Check that the app can reach Lantern with the configured token"
  task status: :environment do
    unless Lantern.config.token.present?
      abort "LANTERN_TOKEN is not set"
    end
    transport = Lantern::Transport::Http.new(Lantern.config)
    if transport.ping
      puts "Lantern OK: #{Lantern.config.ingest_url} (deploy=#{Lantern.config.deploy || 'unset'}, server=#{Lantern.config.server})"
    else
      abort "Lantern unreachable at #{Lantern.config.ingest_url}"
    end
  end

  desc "Send deploy metadata to Lantern: rake lantern:deploy[ref,name,url]"
  task :deploy, [ :ref, :name, :url ] => :environment do |_t, args|
    deploy = Lantern.config.deploy or abort "LANTERN_DEPLOY (or KAMAL_VERSION) is not set"
    uri = URI.join(Lantern.config.ingest_url, "/ingest/deploys")
    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{Lantern.config.token}"
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(deploy: deploy, ref: args[:ref] || (`git rev-parse HEAD 2>/dev/null`.strip.presence),
                             name: args[:name], url: args[:url], server: Lantern.config.server, timestamp: Time.now.utc.iso8601(6))
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
    res.is_a?(Net::HTTPSuccess) ? puts("Deploy #{deploy} recorded") : abort("Deploy failed: #{res.code} #{res.body}")
  end
end
