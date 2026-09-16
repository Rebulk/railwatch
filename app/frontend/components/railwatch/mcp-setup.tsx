import { CopyBlock } from "@/components/railwatch/copy-block"

// Shown with the real token right after one is generated, and with a
// placeholder the rest of the time. `bin/rails railwatch:mcp` in the gem prints
// the same blocks for the same host — keep the two in step.
const PLACEHOLDER = "rwp_your_token_here"

export function mcpClientConfigs(url: string, token: string | null) {
  const bearer = `Bearer ${token ?? PLACEHOLDER}`

  return [
    {
      id: "claude-code",
      label: "Claude Code",
      hint: "Run this in the project you want the assistant to work in.",
      code: `claude mcp add railwatch --transport http ${url} --header "Authorization: ${bearer}"`,
    },
    {
      id: "claude-desktop",
      label: "Claude Desktop",
      hint: "claude_desktop_config.json — Claude Desktop speaks stdio, so mcp-remote bridges it to HTTP.",
      code: JSON.stringify(
        {
          mcpServers: {
            railwatch: {
              command: "npx",
              args: [
                "-y",
                "mcp-remote",
                url,
                "--header",
                `Authorization: ${bearer}`,
              ],
            },
          },
        },
        null,
        2,
      ),
    },
    {
      id: "cursor",
      label: "Cursor",
      hint: ".cursor/mcp.json in the project, or ~/.cursor/mcp.json for every project.",
      code: JSON.stringify(
        {
          mcpServers: {
            railwatch: { url, headers: { Authorization: bearer } },
          },
        },
        null,
        2,
      ),
    },
    {
      id: "vscode",
      label: "VS Code",
      hint: ".vscode/mcp.json in the workspace.",
      code: JSON.stringify(
        {
          servers: {
            railwatch: {
              type: "http",
              url,
              headers: { Authorization: bearer },
            },
          },
        },
        null,
        2,
      ),
    },
    {
      id: "zed",
      label: "Zed",
      hint: "settings.json — also via the mcp-remote bridge.",
      code: JSON.stringify(
        {
          context_servers: {
            railwatch: {
              source: "custom",
              command: "npx",
              args: [
                "-y",
                "mcp-remote",
                url,
                "--header",
                `Authorization: ${bearer}`,
              ],
            },
          },
        },
        null,
        2,
      ),
    },
    {
      id: "curl",
      label: "Test it with curl",
      hint: "Lists every tool the server exposes. If this returns JSON, the token works.",
      code: [
        `curl -sS ${url} \\`,
        `  -H "Authorization: ${bearer}" \\`,
        `  -H "Content-Type: application/json" \\`,
        `  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'`,
      ].join("\n"),
    },
  ]
}

export function McpSetup({
  url,
  token,
}: {
  url: string
  token: string | null
}) {
  return (
    <div className="space-y-4">
      {mcpClientConfigs(url, token).map((client) => (
        <div key={client.id} className="space-y-1">
          <p className="text-sm font-medium">{client.label}</p>
          <p className="text-muted-foreground text-xs">{client.hint}</p>
          <CopyBlock code={client.code} className="mt-1.5" />
        </div>
      ))}
    </div>
  )
}
