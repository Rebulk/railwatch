# Needs attention

The environment overview brings current monitoring problems and recent open
issues into one bounded list. Open an item to inspect monitoring health or the
issue's evidence and history.

Monitoring problems appear first, with critical findings ahead of warnings.
Up to three appear alongside issues; the Monitoring health link opens every
check. Missing evidence is explicit and does not turn an empty issue list into
an all-clear.

Issues must still be open and have their **last recorded occurrence** inside the
selected time window. They rank by priority, recorded affected users, latest
occurrence, then issue ID for stable ties. The list contains at most eight
items. Regressions recorded in that window receive a badge. Historical windows
do not reconstruct past issue state: a resolved issue is excluded, and an issue
whose latest occurrence is after the selected window is also excluded.

The Open issues stat counts all open issues for the environment, across all
time; it is independent of the eight-row recent-issues table. Counts on an
issue are lifetime totals. Exception counts mean recorded occurrences.
Performance and anomaly counts mean breached detector evaluation windows,
not affected requests. Recorded user totals also span the issue's lifetime.

When available, performance and anomaly items include the persisted detector
measurement, threshold and baseline mean. Units are preserved; query durations
in these snapshots are already milliseconds. Missing, malformed or unsupported
snapshots omit numeric evidence. A recorded release is context, not a claim
that the release caused the problem. No new detector evaluations or raw
telemetry scans run when opening the overview.

Monitoring checks describe **now**, even when the issue window is historical.
Their age, sampling, bounded query coverage and other limitations are described
in [Monitoring health](monitoring-health.md). Follow query-related issues into
[Query diagnostics](query-diagnostics.md) for captured plans and index advice.
