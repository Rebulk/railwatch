import { Card, CardContent } from "@/components/ui/card"

// The MCP one-liner is the same command bin/rails railwatch:mcp prints and the
// profile page hands you with a real token in it.
const CLAUDE_CODE_COMMAND =
  'claude mcp add railwatch --transport http https://railwatch.rebulk.com/mcp --header "Authorization: Bearer $RAILWATCH_MCP_TOKEN"'

export function AiAssistant() {
  return (
    <section className="mx-auto max-w-2xl px-6 pb-16 text-center">
      <p className="text-primary mb-2 font-mono text-[11px] tracking-[0.2em] uppercase">
        MCP
      </p>
      <h2 className="text-2xl font-bold tracking-tight">
        Works with your AI assistant
      </h2>
      <p className="text-muted-foreground mt-2">
        Railwatch speaks MCP, so Claude Code, Cursor, VS Code, and Zed can read
        your production data directly — issues, slow routes, query plans, stack
        profiles, logs, deploys. It ships prompts too: point one at an issue key
        and it pulls the occurrence, the timeline around it, and the deploy it
        started after. Writes are attributed to you, so a comment or a status
        change an assistant makes is signed in the issue&apos;s activity feed.
      </p>
      <Card className="mt-6 text-left">
        <CardContent>
          <p className="text-muted-foreground font-mono text-sm">
            # one line, then ask it what broke today
          </p>
          <p className="mt-1 font-mono text-sm break-all">
            {CLAUDE_CODE_COMMAND}
          </p>
        </CardContent>
      </Card>
    </section>
  )
}
