import { Form, router, usePage } from "@inertiajs/react"
import { Bell } from "lucide-react"

import InputError from "@/components/input-error"
import { DataTable } from "@/components/railwatch/data-table"
import { EmptyState } from "@/components/railwatch/empty-state"
import { PageHeader } from "@/components/railwatch/page-header"
import { RelativeTime } from "@/components/railwatch/relative-time"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import EnvLayout from "@/layouts/env-layout"
import * as R from "@/routes"
import type { SharedProps } from "@/types"

interface Threshold {
  id: number
  target_kind: string
  target: string
  metric: string
  limit: number
  window_minutes: number
  description: string
}
interface AnomalyRule {
  id: number
  target_kind: string
  target: string
  metric: string
  deviation: number
  window_minutes: number
  baseline_days: number
  enabled: boolean
  last_fired_at: string | null
  description: string
}
interface Props {
  thresholds: Threshold[]
  routes: string[]
  jobs: string[]
  kinds: string[]
  metrics: string[]
  anomaly_rules: AnomalyRule[]
  anomaly_target_kinds: string[]
  anomaly_metrics: string[]
}

export default function Thresholds(p: Props) {
  const { environment } = usePage<SharedProps>().props
  const a = environment!.application_id
  const e = environment!.id
  return (
    <EnvLayout title="Thresholds">
      <PageHeader
        withWindow={false}
        title="Thresholds"
        description="Performance rules. When a route, job, or query crosses one, Railwatch opens a performance issue and alerts the rules subscribed to thresholds."
      />
      <Card>
        <CardHeader>
          <CardTitle>Add a threshold</CardTitle>
        </CardHeader>
        <CardContent>
          <Form
            method="post"
            action={R.applicationEnvironmentThresholdsPath(a, e)}
            className="grid gap-3 md:grid-cols-6"
          >
            {({ errors, processing }) => (
              <>
                <div className="grid gap-1">
                  <Label htmlFor="target_kind">Kind</Label>
                  <select
                    id="target_kind"
                    name="target_kind"
                    className="border-input h-9 rounded-md border bg-transparent px-2 text-sm"
                  >
                    {p.kinds.map((k) => (
                      <option key={k} value={k}>
                        {k}
                      </option>
                    ))}
                  </select>
                </div>
                <div className="grid gap-1 md:col-span-2">
                  <Label htmlFor="target">Target</Label>
                  <Input
                    id="target"
                    name="target"
                    defaultValue="*"
                    list="targets"
                    placeholder="* for all, or a route / job name"
                  />
                  <datalist id="targets">
                    <option value="*" />
                    <option value="unmatched" />
                    {p.routes.map((r) => (
                      <option key={r} value={r} />
                    ))}
                    {p.jobs.map((j) => (
                      <option key={j} value={j} />
                    ))}
                  </datalist>
                  <InputError messages={errors.target} />
                </div>
                <div className="grid gap-1">
                  <Label htmlFor="metric">Metric</Label>
                  <select
                    id="metric"
                    name="metric"
                    className="border-input h-9 rounded-md border bg-transparent px-2 text-sm"
                  >
                    {p.metrics.map((m) => (
                      <option key={m} value={m}>
                        {m}
                      </option>
                    ))}
                  </select>
                </div>
                <div className="grid gap-1">
                  <Label htmlFor="limit">Limit (ms or %)</Label>
                  <Input
                    id="limit"
                    name="limit"
                    type="number"
                    step="any"
                    defaultValue={2000}
                  />
                  <InputError messages={errors.limit} />
                </div>
                <div className="grid gap-1">
                  <Label htmlFor="window_minutes">Window (min)</Label>
                  <Input
                    id="window_minutes"
                    name="window_minutes"
                    type="number"
                    defaultValue={5}
                  />
                </div>
                <div className="md:col-span-6">
                  <Button disabled={processing}>Add threshold</Button>
                </div>
              </>
            )}
          </Form>
        </CardContent>
      </Card>
      <DataTable
        rows={p.thresholds}
        rowKey={(t) => t.id}
        empty={
          <EmptyState
            icon={Bell}
            title="No thresholds yet"
            description="Start with requests * p95 2000ms to get alerted on regressions."
          />
        }
        columns={[
          {
            key: "d",
            header: "Rule",
            cell: (t) => <span className="text-sm">{t.description}</span>,
          },
          {
            key: "x",
            header: "",
            align: "right",
            cell: (t) => (
              <Button
                size="sm"
                variant="ghost"
                onClick={() =>
                  router.delete(
                    R.applicationEnvironmentThresholdPath(a, e, t.id),
                  )
                }
              >
                Remove
              </Button>
            ),
          },
        ]}
      />
      <div>
        <h2 className="text-base font-semibold">Anomaly rules</h2>
        <p className="text-muted-foreground text-sm">
          A threshold needs a number you already know. An anomaly rule learns
          one: it compares the last few minutes against the same clock window on
          each of the previous days and opens an issue when today sits more than
          the given number of standard deviations above that baseline.
        </p>
      </div>
      <Card>
        <CardHeader>
          <CardTitle>Add an anomaly rule</CardTitle>
        </CardHeader>
        <CardContent>
          <Form
            method="post"
            action={R.applicationEnvironmentAnomalyRulesPath(a, e)}
            className="grid gap-3 md:grid-cols-6"
          >
            {({ errors, processing }) => (
              <>
                <div className="grid gap-1">
                  <Label htmlFor="anomaly_target_kind">Kind</Label>
                  <select
                    id="anomaly_target_kind"
                    name="target_kind"
                    className="border-input h-9 rounded-md border bg-transparent px-2 text-sm"
                  >
                    {p.anomaly_target_kinds.map((k) => (
                      <option key={k} value={k}>
                        {k}
                      </option>
                    ))}
                  </select>
                </div>
                <div className="grid gap-1 md:col-span-2">
                  <Label htmlFor="anomaly_target">Target</Label>
                  <Input
                    id="anomaly_target"
                    name="target"
                    defaultValue="*"
                    list="targets"
                    placeholder="* for all, or a route / job name"
                  />
                  <InputError messages={errors.target} />
                </div>
                <div className="grid gap-1">
                  <Label htmlFor="anomaly_metric">Metric</Label>
                  <select
                    id="anomaly_metric"
                    name="metric"
                    className="border-input h-9 rounded-md border bg-transparent px-2 text-sm"
                  >
                    {p.anomaly_metrics.map((m) => (
                      <option key={m} value={m}>
                        {m}
                      </option>
                    ))}
                  </select>
                </div>
                <div className="grid gap-1">
                  <Label htmlFor="deviation">Deviation (σ)</Label>
                  <Input
                    id="deviation"
                    name="deviation"
                    type="number"
                    step="0.5"
                    min="0.5"
                    defaultValue={3}
                  />
                  <InputError messages={errors.deviation} />
                </div>
                <div className="grid gap-1">
                  <Label htmlFor="anomaly_window_minutes">Window (min)</Label>
                  <Input
                    id="anomaly_window_minutes"
                    name="window_minutes"
                    type="number"
                    defaultValue={15}
                  />
                </div>
                <div className="grid gap-1">
                  <Label htmlFor="baseline_days">Baseline (days)</Label>
                  <Input
                    id="baseline_days"
                    name="baseline_days"
                    type="number"
                    defaultValue={7}
                  />
                  <InputError messages={errors.baseline_days} />
                </div>
                <div className="grid gap-1">
                  <Label htmlFor="enabled">Status</Label>
                  <select
                    id="enabled"
                    name="enabled"
                    className="border-input h-9 rounded-md border bg-transparent px-2 text-sm"
                  >
                    <option value="true">enabled</option>
                    <option value="false">disabled</option>
                  </select>
                </div>
                <div className="md:col-span-6">
                  <Button disabled={processing}>Add anomaly rule</Button>
                </div>
              </>
            )}
          </Form>
        </CardContent>
      </Card>
      <DataTable
        rows={p.anomaly_rules}
        rowKey={(r) => r.id}
        empty={
          <EmptyState
            icon={Bell}
            title="No anomaly rules yet"
            description="Start with requests * p95 at 3σ over a 7-day baseline."
          />
        }
        columns={[
          {
            key: "d",
            header: "Rule",
            cell: (r) => (
              <span className="text-sm">
                {r.description}
                {r.enabled ? null : (
                  <span className="text-muted-foreground label-caps ml-2">
                    disabled
                  </span>
                )}
              </span>
            ),
          },
          {
            key: "f",
            header: "Last fired",
            hideOnMobile: true,
            cell: (r) => (
              <RelativeTime
                iso={r.last_fired_at}
                className="text-muted-foreground font-mono text-xs"
              />
            ),
          },
          {
            key: "x",
            header: "",
            align: "right",
            cell: (r) => (
              <span className="flex justify-end gap-1">
                <Button
                  size="sm"
                  variant="ghost"
                  onClick={() =>
                    router.patch(
                      R.applicationEnvironmentAnomalyRulePath(a, e, r.id),
                      { enabled: !r.enabled },
                    )
                  }
                >
                  {r.enabled ? "Disable" : "Enable"}
                </Button>
                <Button
                  size="sm"
                  variant="ghost"
                  className="text-destructive"
                  onClick={() =>
                    router.delete(
                      R.applicationEnvironmentAnomalyRulePath(a, e, r.id),
                    )
                  }
                >
                  Remove
                </Button>
              </span>
            ),
          },
        ]}
      />
    </EnvLayout>
  )
}
