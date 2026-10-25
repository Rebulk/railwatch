# frozen_string_literal: true

require "erb"
require "json"
require "rails/generators"

module Railwatch
  module Generators
    # Points the coding agents working on this app at its development
    # Railwatch: the MCP server the railwatch-server gem serves at
    # <mount>/mcp (no token needed from this machine in development), and a
    # short note on the dev loop. Every file it touches is either its own or
    # changed only between its markers, so it can be re-run after an upgrade.
    class AgentsGenerator < Rails::Generators::Base
      source_root File.expand_path("templates", __dir__)

      desc "Writes .mcp.json (Claude Code's project MCP servers) with this app's development Railwatch, " \
           "a marked Railwatch block in AGENTS.md and/or CLAUDE.md, and a Claude Code skill. Safe to re-run."

      class_option :url, type: :string,
                         desc: "The MCP endpoint. Default: http://localhost:<PORT or 3000><mount>/mcp."
      class_option :skill, type: :boolean, default: true,
                           desc: "Write .claude/skills/railwatch/SKILL.md."

      SERVER_NAME = "railwatch"
      BEGIN_MARKER = "<!-- BEGIN railwatch (bin/rails generate railwatch:agents) -->"
      END_MARKER = "<!-- END railwatch -->"
      AGENT_FILES = %w[AGENTS.md CLAUDE.md].freeze

      # Claude Code's project scope: { "mcpServers": { name: { "type": "http",
      # "url": ... } } } in .mcp.json at the root
      # (https://code.claude.com/docs/en/mcp, "Project scope"). Only the
      # railwatch entry is written; other servers and keys are kept.
      def write_mcp_json
        path = File.join(destination_root, ".mcp.json")
        config = File.exist?(path) ? JSON.parse(File.read(path)) : {}
        return say("Not touching .mcp.json: its top level is not a JSON object.", :red) unless config.is_a?(Hash)

        servers = config["mcpServers"] ||= {}
        entry = { "type" => "http", "url" => mcp_url }
        return say_status(:identical, ".mcp.json", :blue) if servers[SERVER_NAME] == entry

        servers[SERVER_NAME] = entry
        create_file ".mcp.json", "#{JSON.pretty_generate(config)}\n", force: true
      rescue JSON::ParserError => e
        say("Not touching .mcp.json: it is not valid JSON (#{e.message.lines.first.strip}). Add this under mcpServers yourself: " \
            "#{JSON.generate(SERVER_NAME => { "type" => "http", "url" => mcp_url })}", :red)
      end

      # The block goes into whichever of AGENTS.md and CLAUDE.md exist, and
      # AGENTS.md is created when neither does. Between its markers it is
      # replaced on every run; nothing outside them is changed.
      def write_agent_instructions
        existing = AGENT_FILES.select { |name| File.exist?(File.join(destination_root, name)) }
        (existing.empty? ? [ "AGENTS.md" ] : existing).each { |name| write_block(name, block) }
      end

      # A Claude Code project skill (https://code.claude.com/docs/en/skills):
      # .claude/skills/<name>/SKILL.md, frontmatter `name` and `description`.
      # The whole file is this generator's, rewritten on every run.
      def write_skill
        return unless options[:skill]

        template "SKILL.md", ".claude/skills/railwatch/SKILL.md", force: true
      end

      def show_next_steps
        say <<~STEPS, :green

          Railwatch MCP for this app (development): #{mcp_url}
            Claude Code reads .mcp.json and asks once before it uses a project server.
            Other clients: add the same URL as a streamable HTTP MCP server.
            No token is needed from this machine in development (railwatch-server).
            Anywhere else, send one: Authorization: Bearer rwp_... (Settings -> Profile).
        STEPS
      end

      # `contents` with the marked block replaced by `block`, or with it
      # appended (after a blank line) when there is none. Only the first
      # marked block is replaced; a BEGIN with no END is left alone and the
      # block appended, rather than deleting the rest of the file.
      def self.with_block(contents, block)
        return block if contents.nil? || contents.strip.empty?

        start = contents.index(BEGIN_MARKER)
        finish = start && contents.index(END_MARKER, start)
        if finish
          tail = contents[(finish + END_MARKER.length)..].sub(/\A\n/, "")
          "#{contents[0...start]}#{block}#{tail}"
        else
          "#{contents.sub(/\n*\z/, "\n")}\n#{block}"
        end
      end

      private

      def mcp_url
        options[:url].presence || "http://localhost:#{ENV.fetch("PORT", "3000")}#{mount_path}/mcp"
      end

      def dashboard_url
        mcp_url.delete_suffix("/mcp")
      end

      # The app itself, for the curl in the instructions.
      def app_url
        dashboard_url.delete_suffix(mount_path)
      end

      # The slug railwatch-server gives the app it provisions: the app's
      # module name, parameterized.
      def app_slug
        name = defined?(Rails) && Rails.application ? Rails.application.class.module_parent_name : File.basename(destination_root)
        name.to_s.parameterize
      end

      def mount_path
        path = defined?(Railwatch::Server) && Railwatch::Server.respond_to?(:config) ? Railwatch::Server.config.normalized_mount_path : "/railwatch"
        path.to_s.empty? ? "/railwatch" : path
      end

      def block
        content = ERB.new(File.read(File.join(self.class.source_root, "agents_block.md.tt")), trim_mode: "-").result(binding).strip
        "#{BEGIN_MARKER}\n#{content}\n#{END_MARKER}\n"
      end

      def write_block(name, text)
        path = File.join(destination_root, name)
        current = File.exist?(path) ? File.read(path) : nil
        updated = self.class.with_block(current, text)
        return say_status(:identical, name, :blue) if updated == current

        create_file name, updated, force: true
      end
    end
  end
end
