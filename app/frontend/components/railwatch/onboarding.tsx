import { Link, router } from "@inertiajs/react"
import { RefreshCwIcon } from "lucide-react"

import { CopyBlock } from "@/components/railwatch/copy-block"
import { LiveDot } from "@/components/railwatch/live-dot"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { settingsProfilePath } from "@/routes"

// Shown on Overview and the Application show page while an environment has
// no events yet (environment.last_seen_at is null): a step list to wire up
// the gem plus a "waiting for first event..." status that live-checks via
// router.reload (no full navigation needed once events start arriving).
export function Onboarding({
  tokenPrefix,
  newToken,
  className,
}: {
  tokenPrefix: string
  newToken?: string | null
  className?: string
}) {
  const token = newToken ?? `${tokenPrefix}…`
  const checkNow = () => router.reload()

  return (
    <Card className={className}>
      <CardHeader>
        <CardTitle>Set up this environment</CardTitle>
      </CardHeader>
      <CardContent className="space-y-4">
        <ol className="list-inside list-decimal space-y-3 text-sm">
          <li>
            Add the gem
            <CopyBlock code={'gem "railwatch"'} className="mt-1.5" />
          </li>
          <li>
            Run the generator
            <CopyBlock
              code="bin/rails generate railwatch:install"
              className="mt-1.5"
            />
          </li>
          <li>
            Set the token in the app&apos;s environment
            <CopyBlock code={`RAILWATCH_TOKEN=${token}`} className="mt-1.5" />
            {!newToken && (
              <p className="text-muted-foreground mt-1 text-xs">
                Showing the token prefix only. The full token is shown once,
                right after an environment is created.
              </p>
            )}
          </li>
          <li>
            Check every piece is wired up
            <CopyBlock code="bin/rails railwatch:doctor" className="mt-1.5" />
            <p className="text-muted-foreground mt-1 text-xs">
              Prints a ✓/✗ line per check — token, ingest, middleware, routes,
              deploy marker, browser client, test matchers — and exits non-zero
              if anything required is missing.
            </p>
          </li>
          <li>
            Connect your AI assistant
            <p className="text-muted-foreground mt-1 text-xs">
              Generate a personal token on your{" "}
              <Link
                href={settingsProfilePath()}
                className="underline underline-offset-4"
              >
                profile page
              </Link>{" "}
              for paste-ready Claude Code, Cursor, VS Code, and Zed config.
            </p>
          </li>
          <li>Deploy</li>
        </ol>
        <div className="flex items-center justify-between border-t pt-3">
          <div className="text-muted-foreground flex items-center gap-2 text-xs">
            <LiveDot lastSeenAt={null} />
            Waiting for first event…
          </div>
          <Button type="button" variant="outline" size="sm" onClick={checkNow}>
            <RefreshCwIcon className="size-3.5" />
            Check now
          </Button>
        </div>
      </CardContent>
    </Card>
  )
}
