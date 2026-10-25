# frozen_string_literal: true

require "spec_helper"
require "rails/generators"
require "rails/generators/testing/behavior"
require "rails/generators/testing/assertions"
require "generators/railwatch/agents/agents_generator"
require "fileutils"

RSpec.describe Railwatch::Generators::AgentsGenerator do
  include Rails::Generators::Testing::Behavior
  include Rails::Generators::Testing::Assertions
  include FileUtils

  tests Railwatch::Generators::AgentsGenerator
  destination File.expand_path("../../tmp/agents_generator", __dir__)

  before { prepare_destination }

  def read(name) = File.read(File.join(destination_root, name))
  def write(name, contents) = File.write(File.join(destination_root, name), contents)
  def exist?(name) = File.exist?(File.join(destination_root, name))

  def snapshot
    Dir.glob("**/*", File::FNM_DOTMATCH, base: destination_root).reject { |f| File.directory?(File.join(destination_root, f)) }.sort.to_h { |f| [ f, read(f) ] }
  end

  let(:mcp_url) { "http://localhost:3000/railwatch/mcp" }

  it "points Claude Code at this app's development MCP server in .mcp.json" do
    run_generator

    expect(JSON.parse(read(".mcp.json"))).to eq("mcpServers" => { "railwatch" => { "type" => "http", "url" => mcp_url } })
  end

  it "adds its entry to an existing .mcp.json and keeps every other server and key" do
    write(".mcp.json", JSON.generate("mcpServers" => { "other" => { "command" => "x" }, "railwatch" => { "type" => "http", "url" => "http://old" } }, "extra" => 1))

    run_generator

    expect(JSON.parse(read(".mcp.json"))).to eq(
      "mcpServers" => { "other" => { "command" => "x" }, "railwatch" => { "type" => "http", "url" => mcp_url } }, "extra" => 1
    )
  end

  it "leaves an .mcp.json it cannot parse as it is" do
    write(".mcp.json", "{ not json")

    output = run_generator

    expect(read(".mcp.json")).to eq("{ not json")
    expect(output).to include("Not touching .mcp.json")
  end

  it "creates AGENTS.md with the dev loop when the app has neither AGENTS.md nor CLAUDE.md" do
    run_generator

    agents = read("AGENTS.md")
    expect(agents).to start_with(described_class::BEGIN_MARKER)
    expect(agents).to include(mcp_url, "X-Railwatch-Execution-Id", "get_execution", "get_route", "environment: \"development\"")
    expect(agents).to include("application_slug: \"dummy\""), "the slug railwatch-server provisions: the app module, parameterized"
    expect(exist?("CLAUDE.md")).to be(false)
  end

  it "only names tools the server has today, and says last_execution is still to come" do
    run_generator

    definitions = JSON.parse(File.read(File.expand_path("../fixtures/mcp_tool_names.json", __dir__)))
    named = read("AGENTS.md").scan(/`([a-z_]+)`/).flatten.uniq.select { |word| word.include?("_") && !word.start_with?("application_", "railwatch") }
    expect(named - definitions).to eq([ "last_execution" ])
    expect(read("AGENTS.md")).to match(/`last_execution`.*arrives with a later railwatch-rs release/m)
  end

  it "writes the block into each of AGENTS.md and CLAUDE.md that exists, keeping what is around it" do
    write("AGENTS.md", "# Agents\n\nOur rules.\n")
    write("CLAUDE.md", "# Claude\n")

    run_generator

    expect(read("AGENTS.md")).to start_with("# Agents\n\nOur rules.\n\n#{described_class::BEGIN_MARKER}\n")
    expect(read("CLAUDE.md")).to start_with("# Claude\n\n#{described_class::BEGIN_MARKER}\n")
    expect(read("CLAUDE.md")).to end_with("#{described_class::END_MARKER}\n")
  end

  it "does not create AGENTS.md when only CLAUDE.md exists" do
    write("CLAUDE.md", "# Claude\n")

    run_generator

    expect(exist?("AGENTS.md")).to be(false)
    expect(read("CLAUDE.md")).to include(described_class::BEGIN_MARKER)
  end

  it "changes nothing on a second run" do
    write("AGENTS.md", "# Agents\n")
    write("CLAUDE.md", "# Claude\n")
    run_generator
    first = snapshot

    output = run_generator

    expect(snapshot).to eq(first)
    expect(output).not_to match(/\b(create|force)\b/)
    expect(read("AGENTS.md").scan(described_class::BEGIN_MARKER).size).to eq(1)
  end

  it "replaces only its own block when re-run, whatever the user wrote before or after it" do
    write("AGENTS.md", "# Agents\n\n#{described_class::BEGIN_MARKER}\nstale railwatch text\n#{described_class::END_MARKER}\n\n## Ours\n\nKeep this.\n")

    run_generator

    agents = read("AGENTS.md")
    expect(agents).not_to include("stale railwatch text")
    expect(agents).to start_with("# Agents\n\n#{described_class::BEGIN_MARKER}\n")
    expect(agents).to end_with("#{described_class::END_MARKER}\n\n## Ours\n\nKeep this.\n")
  end

  it "appends rather than truncates when its BEGIN marker has no END" do
    write("AGENTS.md", "#{described_class::BEGIN_MARKER}\nuser text after a broken marker\n")

    run_generator

    expect(read("AGENTS.md")).to include("user text after a broken marker")
    expect(read("AGENTS.md")).to end_with("#{described_class::END_MARKER}\n")
  end

  it "writes a Claude Code skill with the frontmatter Claude Code reads" do
    run_generator

    skill = read(".claude/skills/railwatch/SKILL.md")
    frontmatter = YAML.safe_load(skill[/\A---\n(.*?)\n---\n/m, 1])
    expect(frontmatter.keys).to eq(%w[name description])
    expect(frontmatter["name"]).to eq("railwatch")
    expect(frontmatter["description"].length).to be < 1_536
    expect(skill).to include(mcp_url, "get_execution")
  end

  it "skips the skill with --no-skill" do
    run_generator %w[--no-skill]

    expect(exist?(".claude/skills/railwatch/SKILL.md")).to be(false)
  end

  it "takes another endpoint with --url" do
    run_generator %w[--url http://localhost:4000/railwatch/mcp]

    expect(JSON.parse(read(".mcp.json")).dig("mcpServers", "railwatch", "url")).to eq("http://localhost:4000/railwatch/mcp")
    expect(read("AGENTS.md")).to include("curl -si http://localhost:4000/path")
  end
end
