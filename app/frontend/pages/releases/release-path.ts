import * as R from "@/routes"

// A release is identified by its deploy string, and Rails reads a dot in a
// path segment as a format separator, so /releases/v1.2.3 would arrive as id
// "v1" with format "2.3". js-routes escapes everything else in a segment but
// leaves dots alone, so percent-encode them here; the query string (which
// never holds the deploy) is left as it was generated. String() because
// eslint does not type-check the generated app/frontend/routes module.
export function releasePath(
  applicationId: number,
  environmentId: number,
  deploy: string,
  options?: { window?: string },
) {
  const url = String(
    R.applicationEnvironmentReleasePath(
      applicationId,
      environmentId,
      deploy,
      options,
    ),
  )
  const [path, query] = url.split("?")
  return `${path.replace(/\./g, "%2E")}${query ? `?${query}` : ""}`
}
