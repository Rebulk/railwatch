import { Link } from "@inertiajs/react"

import { tenantPath } from "@/pages/tenants/tenant-path"
import * as R from "@/routes"
import type { TelemetryTimeParams, Window, WindowRange } from "@/types"

export interface OriginIdentityData {
  user_ref: string | null
  tenant: string | null
  person: { ref: string; name: string } | null
}

function personPath(
  applicationId: number,
  environmentId: number,
  ref: string,
  timeParams: TelemetryTimeParams,
) {
  const url = String(
    R.applicationEnvironmentPersonPath(applicationId, environmentId, ref, {
      ...timeParams,
    }),
  )
  const [path, query] = url.split("?")
  return `${path.replace(/\./g, "%2E")}${query ? `?${query}` : ""}`
}

interface Props extends OriginIdentityData {
  applicationId: number
  environmentId: number
  kind: "user" | "tenant"
  window?: Window
  range?: WindowRange
}

function identityTimeParams(
  window: Window | undefined,
  range: WindowRange | undefined,
): TelemetryTimeParams {
  if (window === "custom") {
    if (!range) throw new Error("Custom telemetry window requires a range")
    return { from: range.from, to: range.to }
  }
  return { window: window ?? "24h" }
}

// A propagated job identity describes the enqueue origin. A Person link is
// only offered when this environment has a matching user record; the raw ref
// remains useful for older payloads that never emitted one.
export function OriginIdentity({
  applicationId,
  environmentId,
  kind,
  person,
  range,
  tenant,
  user_ref,
  window,
}: Props) {
  if (kind === "user") {
    if (!user_ref) return <span className="text-muted-foreground">–</span>
    if (!person) return <span className="font-mono text-xs">{user_ref}</span>
    const timeParams = identityTimeParams(window, range)
    return (
      <Link
        className="font-mono text-xs hover:underline"
        href={personPath(applicationId, environmentId, person.ref, timeParams)}
      >
        {person.name}
      </Link>
    )
  }

  if (!tenant) return <span className="text-muted-foreground">–</span>
  const timeParams = identityTimeParams(window, range)
  return (
    <Link
      className="font-mono text-xs hover:underline"
      href={tenantPath(applicationId, environmentId, tenant, timeParams)}
    >
      {tenant}
    </Link>
  )
}
