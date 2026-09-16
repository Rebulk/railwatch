import { Card, CardContent } from "@/components/ui/card"

// Mirrors the gem's docs/getting-started.md. If the steps there change, change
// them here — this is the first thing anyone evaluating Railwatch reads.
const STEPS: { comment: string; lines: string[] }[] = [
  { comment: "# 1. add the gem", lines: ["bundle add railwatch"] },
  {
    comment: "# 2. initializer, routes, Kamal hook, browser client, matchers",
    lines: [
      "bin/rails generate railwatch:install --token=rw_… --kamal-secrets",
    ],
  },
  {
    comment: "# 3. check every piece is wired up",
    lines: ["bin/rails railwatch:doctor"],
  },
  {
    comment: "# 4. connect your editor's assistant",
    lines: ["bin/rails railwatch:mcp"],
  },
]

export function InstallSnippet() {
  return (
    <section className="mx-auto max-w-2xl px-6 pb-16 text-center">
      <p className="text-primary mb-2 font-mono text-[11px] tracking-[0.2em] uppercase">
        Install
      </p>
      <h2 className="text-2xl font-bold tracking-tight">Five-minute install</h2>
      <p className="text-muted-foreground mt-2">
        One gem, one generator, no dashboard to build. The generator finishes by
        running the doctor, so you see a ✓ or a ✗ per check before you deploy.
      </p>
      <Card className="mt-6 text-left">
        <CardContent className="space-y-1 font-mono text-sm">
          {STEPS.map((step, index) => (
            <div key={step.comment} className={index > 0 ? "pt-3" : undefined}>
              <p className="text-muted-foreground">{step.comment}</p>
              {step.lines.map((line) => (
                <p key={line} className="break-all">
                  {line}
                </p>
              ))}
            </div>
          ))}
        </CardContent>
      </Card>
    </section>
  )
}
