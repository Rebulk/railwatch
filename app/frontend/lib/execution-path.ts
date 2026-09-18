import * as R from "@/routes"

interface ExecutionPathOptions {
  applicationId: number
  environmentId: number
  source: string | null | undefined
  executionId: string | null | undefined
}

// Child telemetry uses `job` while the parent record itself is a
// `job_attempt`, so accept both wire names. Unknown server-side parent kinds
// use the generic execution surface; browser events intentionally have no
// server execution to open.
export function executionPath({
  applicationId,
  environmentId,
  source,
  executionId,
}: ExecutionPathOptions): string | null {
  if (!executionId || source === "browser") return null

  switch (source) {
    case "request":
      return R.applicationEnvironmentRequestPath(
        applicationId,
        environmentId,
        executionId,
      )
    case "job":
    case "job_attempt":
      return R.applicationEnvironmentJobPath(
        applicationId,
        environmentId,
        executionId,
      )
    case "scheduled_task":
      return R.applicationEnvironmentScheduledTaskPath(
        applicationId,
        environmentId,
        executionId,
      )
    case "command":
      return R.applicationEnvironmentCommandPath(
        applicationId,
        environmentId,
        executionId,
      )
    default:
      return R.applicationEnvironmentExecutionPath(
        applicationId,
        environmentId,
        executionId,
      )
  }
}
