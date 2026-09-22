import { Badge } from "@/components/ui/badge"
import {
  Card,
  CardContent,
  CardDescription,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"

import type { QueryDiagnostics, QueryRecommendation } from "./diagnostics-types"

const basisLabels: Record<QueryRecommendation["basis"], string> = {
  sql: "SQL heuristic",
  plan: "Captured plan",
  capture: "Captured repetition",
}

export function DiagnosticsPanel({
  diagnostics,
}: {
  diagnostics: QueryDiagnostics
}) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Query diagnostics</CardTitle>
        <CardDescription>
          Review captured evidence and validate candidates on the source
          database.
        </CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-4">
        <dl className="flex flex-wrap gap-x-6 gap-y-2 text-xs">
          <div>
            <dt className="text-muted-foreground">Connection</dt>
            <dd className="font-mono">
              {diagnostics.connection || "Not captured"}
            </dd>
          </div>
          <div>
            <dt className="text-muted-foreground">Adapter</dt>
            <dd className="font-mono">
              {diagnostics.adapter || "Not captured"}
            </dd>
          </div>
          {diagnostics.source && (
            <div>
              <dt className="text-muted-foreground">Sample source</dt>
              <dd className="font-mono break-all">{diagnostics.source}</dd>
            </div>
          )}
        </dl>
        <ul className="text-muted-foreground flex list-disc flex-col gap-1 pl-4 text-xs">
          {diagnostics.limitations.map((limitation) => (
            <li key={limitation}>{limitation}</li>
          ))}
        </ul>
        {diagnostics.recommendations.length === 0 && (
          <p className="text-muted-foreground text-sm">
            {diagnostics.status === "analyzed"
              ? "No supported index candidate or plan observation was found. This does not establish that the query is optimal."
              : "The captured evidence is insufficient for specific SQL advice. Review the statement and source below."}
          </p>
        )}
        {diagnostics.recommendations.map((recommendation) => (
          <article
            key={recommendation.id}
            className="flex flex-col gap-2 rounded-lg border p-3"
          >
            <div className="flex flex-wrap items-center gap-2">
              <h3 className="text-sm font-medium">{recommendation.title}</h3>
              <Badge
                variant={
                  recommendation.basis === "sql" ? "outline" : "secondary"
                }
              >
                {basisLabels[recommendation.basis]}
              </Badge>
            </div>
            <p className="text-muted-foreground text-xs">
              {recommendation.explanation}
            </p>
            <p className="text-xs">{recommendation.action}</p>
            {recommendation.code && (
              <div className="flex flex-col gap-1">
                <p className="text-muted-foreground text-xs">
                  Rails example · verify association names
                </p>
                <pre className="bg-muted overflow-x-auto rounded p-2 font-mono text-xs whitespace-pre-wrap">
                  {recommendation.code}
                </pre>
              </div>
            )}
            <details className="text-xs">
              <summary className="text-muted-foreground cursor-pointer">
                Evidence
              </summary>
              <div className="mt-2 flex flex-col gap-2">
                {recommendation.evidence.map((evidence, index) => (
                  <div key={index}>
                    <p className="text-muted-foreground mb-1">
                      {evidence.source === "plan"
                        ? "Stored plan"
                        : evidence.source === "source"
                          ? "Captured source"
                          : evidence.source === "n_plus_one"
                            ? "Captured N+1 repetition"
                            : "Captured SQL shape"}
                      {evidence.line && ` · line ${evidence.line}`}
                      {evidence.truncated && " · excerpt truncated"}
                    </p>
                    <pre className="bg-muted overflow-x-auto rounded p-2 font-mono break-all whitespace-pre-wrap">
                      {evidence.text}
                    </pre>
                  </div>
                ))}
              </div>
            </details>
          </article>
        ))}
      </CardContent>
    </Card>
  )
}
