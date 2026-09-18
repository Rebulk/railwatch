import * as R from "@/routes"
import type { Window } from "@/types"

// Rails reads a dot in a path segment as a format separator, so
// /tenants/acme.co would arrive as id "acme" with format "co". js-routes
// escapes everything else in a segment but leaves dots alone, so percent-
// encode them here; the query string (which never holds the tenant) is left
// as it was generated. String() because eslint does not type-check the
// generated app/frontend/routes module.
export function tenantPath(
  applicationId: number,
  environmentId: number,
  tenant: string,
  options?: { window?: Window; from?: string; to?: string },
) {
  const url = String(
    R.applicationEnvironmentTenantPath(
      applicationId,
      environmentId,
      tenant,
      options,
    ),
  )
  const [path, query] = url.split("?")
  return `${path.replace(/\./g, "%2E")}${query ? `?${query}` : ""}`
}
