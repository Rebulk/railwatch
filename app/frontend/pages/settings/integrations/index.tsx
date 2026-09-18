import { Form, Head, router } from "@inertiajs/react"
import { useState } from "react"

import InputError from "@/components/input-error"
import { DataTable } from "@/components/railwatch/data-table"
import { RelativeTime } from "@/components/railwatch/relative-time"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Checkbox } from "@/components/ui/checkbox"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import AppLayout from "@/layouts/app-layout"
import * as R from "@/routes"

interface Integration {
  id: number
  kind: string
  name: string
  enabled: boolean
  // What this integration actually points at. The name beside it is free
  // text and may say something else entirely, so this is the field to trust
  // when two integrations look alike.
  destination: string | null
  last_delivered_at: string | null
  last_received_at: string | null
  last_synced_at: string | null
  last_error: string | null
  settings: {
    team_id?: string
    organization_name?: string
    team_options?: { id: string; key: string; name: string }[]
    revoked_at?: string
    credential?: string
    oauth?: boolean
    [key: string]: unknown
  }
  webhook_health: {
    failed: number
    pending: number
    last_event_at: string | null
  } | null
}

// Slack incoming webhooks never reveal which channel they post to, so the
// most we can show is the hook id from the URL.
const destinationHint: Record<string, string> = {
  slack: "Slack hook id — incoming webhooks do not expose their channel",
}
// The one setting per kind that is a credential and can be replaced in
// place (Settings::IntegrationsController#update merges it in). Email and
// plain webhooks have nothing secret to rotate beyond re-creating them.
const secretField: Record<string, { key: string; label: string }> = {
  slack: { key: "webhook_url", label: "New Slack incoming webhook URL" },
  webhook: { key: "secret", label: "New signing secret" },
  linear: { key: "api_key", label: "New Linear API key" },
}

// window.prompt rather than a dialog: the value is pasted once, never shown
// again, and the page has no other reason to hold it in state.
function rotateSecret(integration: Integration) {
  const field = secretField[integration.kind]
  if (!field) return
  const value = window.prompt(field.label)?.trim()
  if (!value) return
  router.patch(R.settingsIntegrationPath(integration.id), {
    enabled: true,
    settings: { [field.key]: value },
  })
}

interface Filters {
  environment_ids?: number[]
  kinds?: string[]
  min_priority?: string
  title_pattern?: string
}
interface Rule {
  id: number
  event: string
  application: string
  application_id: number
  integration: string
  integration_id: number
  filters: Filters
}
interface Props {
  integrations: Integration[]
  alert_rules: Rule[]
  application_options: { id: number; name: string }[]
  environment_options: Record<number, { id: number; name: string }[]>
  events: string[]
  kinds: string[]
  issue_kinds: string[]
  priorities: string[]
  linear_oauth_enabled: boolean
}

const eventLabel: Record<string, string> = {
  new_issue: "New issue",
  regressed_issue: "Regressed or reopened issue",
  resolved_issue: "Issue resolved",
  ignored_issue: "Issue ignored",
  assigned_issue: "Issue assigned",
  threshold: "Threshold exceeded",
  quota: "Quota reached",
}

// "production · anomaly · >= high · /timeout/", or nothing when the rule
// notifies about everything its event covers.
function filterSummary(rule: Rule, environments: Props["environment_options"]) {
  const f = rule.filters ?? {}
  const names = (environments[rule.application_id] ?? [])
    .filter((e) => (f.environment_ids ?? []).includes(e.id))
    .map((e) => e.name)
  return [
    ...names,
    ...(f.kinds ?? []),
    f.min_priority ? `>= ${f.min_priority}` : null,
    f.title_pattern,
  ]
    .filter(Boolean)
    .join(" · ")
}

export default function Integrations(p: Props) {
  const [kind, setKind] = useState("slack")
  const [applicationId, setApplicationId] = useState(
    p.application_options[0]?.id,
  )
  return (
    <AppLayout
      breadcrumbs={[
        { title: "Integrations", href: R.settingsIntegrationsPath() },
      ]}
    >
      <Head title="Integrations" />
      <div className="flex flex-1 flex-col gap-6 p-4 md:p-6">
        <div>
          <h1 className="text-xl font-semibold">Integrations and alerts</h1>
          <p className="text-muted-foreground text-sm">
            Where alerts go, and which events trigger them per application.
          </p>
        </div>
        <div className="grid gap-6 lg:grid-cols-2">
          <Card>
            <CardHeader>
              <CardTitle className="text-sm">Add integration</CardTitle>
            </CardHeader>
            <CardContent>
              <Form
                method="post"
                action={R.settingsIntegrationsPath()}
                className="space-y-3"
                resetOnSuccess
              >
                {({ errors, processing }) => (
                  <>
                    <div className="grid gap-1">
                      <Label htmlFor="kind">Kind</Label>
                      <select
                        id="kind"
                        name="kind"
                        value={kind}
                        onChange={(e) => setKind(e.target.value)}
                        className="border-input h-9 rounded-md border bg-transparent px-2 text-sm"
                      >
                        {p.kinds.map((k) => (
                          <option key={k} value={k}>
                            {k}
                          </option>
                        ))}
                      </select>
                    </div>
                    {!(kind === "linear" && p.linear_oauth_enabled) && (
                      <div className="grid gap-1">
                        <Label htmlFor="name">Name</Label>
                        <Input
                          id="name"
                          name="name"
                          required
                          placeholder="#alerts"
                        />
                        <InputError messages={errors.name} />
                      </div>
                    )}
                    {kind === "email" && (
                      <div className="grid gap-1">
                        <Label htmlFor="to">Send to</Label>
                        <Input
                          id="to"
                          name="settings[to]"
                          type="email"
                          required
                        />
                      </div>
                    )}
                    {kind === "slack" && (
                      <div className="grid gap-1">
                        <Label htmlFor="webhook_url">
                          Incoming webhook URL
                        </Label>
                        <Input
                          id="webhook_url"
                          name="settings[webhook_url]"
                          type="url"
                          required
                          placeholder="https://hooks.slack.com/services/…"
                        />
                      </div>
                    )}
                    {kind === "webhook" && (
                      <>
                        <div className="grid gap-1">
                          <Label htmlFor="url">URL</Label>
                          <Input
                            id="url"
                            name="settings[url]"
                            type="url"
                            required
                          />
                        </div>
                        <div className="grid gap-1">
                          <Label htmlFor="secret">
                            Signing secret (optional)
                          </Label>
                          <Input id="secret" name="settings[secret]" />
                          <p className="text-muted-foreground text-xs">
                            Sent as X-Railwatch-Signature: sha256=HMAC(body).
                          </p>
                        </div>
                      </>
                    )}
                    {kind === "linear" && p.linear_oauth_enabled && (
                      <div className="bg-muted/40 space-y-2 rounded-md border p-3">
                        <p className="text-sm">
                          Linear uses OAuth to discover your workspace and
                          teams. Connect your workspace, then select a team.
                        </p>
                        <p className="text-muted-foreground text-xs">
                          Railwatch names the integration from the Linear
                          workspace.
                        </p>
                      </div>
                    )}
                    {kind === "linear" && !p.linear_oauth_enabled && (
                      <>
                        <div className="grid gap-1">
                          <Label htmlFor="api_key">API key</Label>
                          <Input
                            id="api_key"
                            name="settings[api_key]"
                            required
                          />
                        </div>
                        <div className="grid gap-1">
                          <Label htmlFor="team_id">Team ID</Label>
                          <Input
                            id="team_id"
                            name="settings[team_id]"
                            required
                          />
                        </div>
                      </>
                    )}
                    <InputError messages={errors.settings} />
                    {kind === "linear" && p.linear_oauth_enabled ? (
                      <Button
                        type="button"
                        onClick={() => router.post(R.settingsLinearOauthPath())}
                      >
                        Connect Linear workspace
                      </Button>
                    ) : (
                      <Button disabled={processing}>Add</Button>
                    )}
                  </>
                )}
              </Form>
            </CardContent>
          </Card>
          <Card>
            <CardHeader>
              <CardTitle className="text-sm">Add alert rule</CardTitle>
            </CardHeader>
            <CardContent>
              <Form
                method="post"
                action={R.settingsAlertRulesPath()}
                className="space-y-3"
              >
                {({ errors, processing }) => (
                  <>
                    <div className="grid gap-1">
                      <Label htmlFor="application_id">Application</Label>
                      <select
                        id="application_id"
                        name="application_id"
                        value={applicationId ?? ""}
                        onChange={(e) =>
                          setApplicationId(Number(e.target.value))
                        }
                        className="border-input h-9 rounded-md border bg-transparent px-2 text-sm"
                      >
                        {p.application_options.map((a) => (
                          <option key={a.id} value={a.id}>
                            {a.name}
                          </option>
                        ))}
                      </select>
                    </div>
                    <div className="grid gap-1">
                      <Label htmlFor="event">When</Label>
                      <select
                        id="event"
                        name="event"
                        className="border-input h-9 rounded-md border bg-transparent px-2 text-sm"
                      >
                        {p.events.map((e) => (
                          <option key={e} value={e}>
                            {eventLabel[e] ?? e}
                          </option>
                        ))}
                      </select>
                    </div>
                    <div className="grid gap-1">
                      <Label htmlFor="integration_id">Notify</Label>
                      <select
                        id="integration_id"
                        name="integration_id"
                        className="border-input h-9 rounded-md border bg-transparent px-2 text-sm"
                      >
                        {p.integrations.map((i) => (
                          <option key={i.id} value={i.id}>
                            {i.name} ({i.kind})
                          </option>
                        ))}
                      </select>
                    </div>
                    <div className="space-y-3 border-t pt-3">
                      <p className="label-caps">Only notify when (optional)</p>
                      <div className="grid gap-1">
                        <span className="text-sm">Environments</span>
                        <div className="flex flex-wrap gap-x-4 gap-y-2">
                          {(
                            p.environment_options[applicationId ?? 0] ?? []
                          ).map((env) => (
                            <Label
                              key={env.id}
                              className="text-muted-foreground gap-1.5 font-normal"
                            >
                              <Checkbox
                                name="filters[environment_ids][]"
                                value={String(env.id)}
                              />
                              {env.name}
                            </Label>
                          ))}
                        </div>
                      </div>
                      <div className="grid gap-1">
                        <span className="text-sm">Issue kinds</span>
                        <div className="flex flex-wrap gap-x-4 gap-y-2">
                          {p.issue_kinds.map((issueKind) => (
                            <Label
                              key={issueKind}
                              className="text-muted-foreground gap-1.5 font-normal"
                            >
                              <Checkbox
                                name="filters[kinds][]"
                                value={issueKind}
                              />
                              {issueKind}
                            </Label>
                          ))}
                        </div>
                      </div>
                      <div className="grid gap-1">
                        <Label htmlFor="min_priority">Minimum priority</Label>
                        <select
                          id="min_priority"
                          name="filters[min_priority]"
                          className="border-input h-9 rounded-md border bg-transparent px-2 text-sm"
                        >
                          <option value="">any</option>
                          {p.priorities.map((priority) => (
                            <option key={priority} value={priority}>
                              {priority}
                            </option>
                          ))}
                        </select>
                      </div>
                      <div className="grid gap-1">
                        <Label htmlFor="title_pattern">Title matches</Label>
                        <Input
                          id="title_pattern"
                          name="filters[title_pattern]"
                          placeholder="timeout, or /Redis.*timeout/"
                        />
                        <p className="text-muted-foreground text-xs">
                          Case-insensitive substring, or a regular expression
                          when wrapped in slashes.
                        </p>
                      </div>
                    </div>
                    <InputError messages={errors.event} />
                    <Button
                      disabled={processing || p.integrations.length === 0}
                    >
                      Add rule
                    </Button>
                  </>
                )}
              </Form>
            </CardContent>
          </Card>
        </div>
        <DataTable
          rows={p.integrations}
          rowKey={(i) => i.id}
          empty="No integrations yet."
          columns={[
            {
              key: "n",
              header: "Integration",
              cell: (i) => <span className="font-medium">{i.name}</span>,
            },
            {
              key: "k",
              header: "Kind",
              cell: (i) => <Badge variant="outline">{i.kind}</Badge>,
            },
            {
              key: "s",
              header: "Destination",
              cell: (i) => (
                <span
                  className="font-mono text-xs"
                  title={destinationHint[i.kind]}
                >
                  {i.destination ?? "—"}
                </span>
              ),
            },
            {
              key: "d",
              header: "Health",
              hideOnMobile: true,
              cell: (i) => (
                <span className="flex flex-col gap-0.5">
                  <span className="text-muted-foreground text-xs">
                    {i.kind === "linear" ? "Last sync " : "Last delivery "}
                    <RelativeTime
                      iso={
                        i.kind === "linear"
                          ? i.last_synced_at
                          : i.last_delivered_at
                      }
                    />
                  </span>
                  {i.kind === "linear" && i.webhook_health && (
                    <span className="text-muted-foreground text-xs">
                      Webhooks: {i.webhook_health.pending} pending ·{" "}
                      {i.webhook_health.failed} failed
                    </span>
                  )}
                  {i.last_error && (
                    <span
                      className="text-destructive max-w-64 truncate text-xs"
                      title={i.last_error}
                    >
                      {i.last_error}
                    </span>
                  )}
                </span>
              ),
            },
            {
              key: "e",
              header: "",
              cell: (i) =>
                i.enabled ? null : <Badge variant="secondary">disabled</Badge>,
            },
            {
              key: "x",
              header: "",
              align: "right",
              cell: (i) => (
                <span className="flex flex-wrap justify-end gap-1">
                  {i.kind === "linear" &&
                    (i.settings.team_options?.length ?? 0) > 0 && (
                      <select
                        aria-label={`Linear team for ${i.name}`}
                        value={i.settings.team_id ?? ""}
                        onChange={(event) =>
                          router.patch(R.settingsIntegrationPath(i.id), {
                            enabled: true,
                            settings: { team_id: event.target.value },
                          })
                        }
                        className="border-input h-8 rounded-md border bg-transparent px-2 text-xs"
                      >
                        <option value="">Select team…</option>
                        {i.settings.team_options?.map((team) => (
                          <option key={team.id} value={team.id}>
                            {team.name} ({team.key})
                          </option>
                        ))}
                      </select>
                    )}
                  <Button
                    size="sm"
                    variant="ghost"
                    onClick={() =>
                      router.post(
                        R.sendTestSettingsIntegrationPath(i.id),
                        {},
                        { preserveScroll: true },
                      )
                    }
                  >
                    Send test
                  </Button>
                  {secretField[i.kind] &&
                    !(i.kind === "linear" && i.settings.oauth) && (
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={() => rotateSecret(i)}
                      >
                        Rotate
                      </Button>
                    )}
                  {i.kind === "linear" &&
                    i.settings.oauth &&
                    i.settings.credential && (
                      <Button
                        size="sm"
                        variant="ghost"
                        onClick={() =>
                          router.delete(
                            R.settingsDisconnectLinearOauthPath(i.id),
                          )
                        }
                      >
                        Disconnect
                      </Button>
                    )}
                  <Button
                    size="sm"
                    variant="ghost"
                    onClick={() =>
                      router.patch(R.settingsIntegrationPath(i.id), {
                        enabled: !i.enabled,
                      })
                    }
                  >
                    {i.enabled ? "Disable" : "Enable"}
                  </Button>
                  <Button
                    size="sm"
                    variant="ghost"
                    className="text-destructive"
                    onClick={() =>
                      router.delete(R.settingsIntegrationPath(i.id))
                    }
                  >
                    Remove
                  </Button>
                </span>
              ),
            },
          ]}
        />
        <DataTable
          rows={p.alert_rules}
          rowKey={(r) => r.id}
          empty="No alert rules yet."
          columns={[
            { key: "a", header: "Application", cell: (r) => r.application },
            {
              key: "e",
              header: "When",
              cell: (r) => eventLabel[r.event] ?? r.event,
            },
            { key: "i", header: "Notify", cell: (r) => r.integration },
            {
              key: "f",
              header: "Only when",
              hideOnMobile: true,
              cell: (r) => (
                <span className="text-muted-foreground font-mono text-xs">
                  {filterSummary(r, p.environment_options) || "—"}
                </span>
              ),
            },
            {
              key: "x",
              header: "",
              align: "right",
              cell: (r) => (
                <Button
                  size="sm"
                  variant="ghost"
                  className="text-destructive"
                  onClick={() => router.delete(R.settingsAlertRulePath(r.id))}
                >
                  Remove
                </Button>
              ),
            },
          ]}
        />
      </div>
    </AppLayout>
  )
}
