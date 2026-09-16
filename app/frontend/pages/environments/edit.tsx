import { Form, Head } from "@inertiajs/react"

import InputError from "@/components/input-error"
import { RelativeTime } from "@/components/railwatch/relative-time"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import AppLayout from "@/layouts/app-layout"
import { cn } from "@/lib/utils"
import * as R from "@/routes"

interface KamalConfig {
  version?: string | null
  roles?: string[] | null
  performer?: string | null
  destination?: string | null
  service?: string | null
  recorded_at?: string | null
  hosts?: string[] | null
  command?: string | null
  subcommand?: string | null
  received_at?: string | null
}

const SERVER_SNIPPET = `# Nothing to add under Kamal: the gem already stamps records with
# KAMAL_HOST, the same host the post-deploy hook registers here.
# Anywhere else, name the host yourself:
Railwatch.configure do |c|
  c.server = ENV["RAILWATCH_SERVER"] || Socket.gethostname
end`

export default function EditEnvironment(p: {
  application: { id: number; name: string }
  environment: {
    id: number
    name: string
    slug: string
    token_prefix: string
    expected_servers: string[]
    kamal_config: KamalConfig
    crash_free_threshold: number | null
  }
  silent_servers: string[]
}) {
  const kamal = p.environment.kamal_config
  const hosts = p.environment.expected_servers
  return (
    <AppLayout
      breadcrumbs={[
        {
          title: p.application.name,
          href: R.applicationPath(p.application.id),
        },
        { title: p.environment.name, href: "#" },
      ]}
    >
      <Head title={`Edit ${p.environment.name}`} />
      <div className="mx-auto w-full max-w-2xl space-y-4 p-4 md:p-6">
        <Card>
          <CardHeader>
            <CardTitle>Edit environment</CardTitle>
          </CardHeader>
          <CardContent>
            <Form
              method="patch"
              action={R.applicationEnvironmentPath(
                p.application.id,
                p.environment.id,
              )}
              className="space-y-4"
            >
              {({ errors, processing }) => (
                <>
                  <div className="grid gap-2">
                    <Label htmlFor="name">Name</Label>
                    <Input
                      id="name"
                      name="name"
                      defaultValue={p.environment.name}
                      required
                    />
                    <InputError messages={errors.name} />
                  </div>
                  <div className="grid gap-2">
                    <Label htmlFor="expected_servers">Expected servers</Label>
                    <Textarea
                      id="expected_servers"
                      name="expected_servers"
                      rows={4}
                      className="font-mono text-xs"
                      defaultValue={hosts.join("\n")}
                      placeholder={"web-1\nweb-2"}
                    />
                    <p className="text-muted-foreground text-xs">
                      One host per line. Railwatch alerts (silent host) when one
                      of these stops reporting for 10 minutes. The Kamal
                      post-deploy hook rewrites this list after every deploy.
                    </p>
                    <InputError messages={errors.expected_servers} />
                  </div>
                  <div className="grid gap-2">
                    <Label htmlFor="crash_free_threshold">
                      Crash-free session threshold
                    </Label>
                    <Input
                      id="crash_free_threshold"
                      name="crash_free_threshold"
                      type="number"
                      step="0.1"
                      min="0"
                      max="100"
                      defaultValue={p.environment.crash_free_threshold ?? ""}
                    />
                    <p className="text-muted-foreground text-xs">
                      Percent. Railwatch alerts (crash-free drop) when the
                      current release falls below this over an hour, with at
                      least 20 sessions.
                    </p>
                    <InputError messages={errors.crash_free_threshold} />
                  </div>
                  <p className="text-muted-foreground text-xs">
                    Tenant slug{" "}
                    <span className="font-mono">{p.environment.slug}</span> ·
                    token {p.environment.token_prefix}…
                  </p>
                  <Button disabled={processing}>Save</Button>
                </>
              )}
            </Form>
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Kamal</CardTitle>
          </CardHeader>
          <CardContent className="space-y-4">
            {kamal.version ? (
              <dl className="grid grid-cols-2 gap-3 text-sm md:grid-cols-3">
                {[
                  ["Service", kamal.service],
                  ["Destination", kamal.destination],
                  ["Version", kamal.version],
                  ["Performer", kamal.performer],
                  ["Roles", kamal.roles?.join(", ")],
                ].map(([label, value]) => (
                  <div key={label}>
                    <dt className="label-caps">{label}</dt>
                    <dd className="truncate font-mono text-xs">
                      {value?.length ? value : "—"}
                    </dd>
                  </div>
                ))}
                <div>
                  <dt className="label-caps">Deployed</dt>
                  <dd className="font-mono text-xs">
                    <RelativeTime
                      iso={kamal.recorded_at ?? kamal.received_at}
                    />
                  </dd>
                </div>
              </dl>
            ) : (
              <p className="text-muted-foreground text-sm">
                No deploy reported yet. Run{" "}
                <span className="font-mono">
                  bin/rails generate railwatch:install
                </span>{" "}
                to create{" "}
                <span className="font-mono">.kamal/hooks/post-deploy</span>; it
                posts the host list after every deploy.
              </p>
            )}
            {hosts.length > 0 && (
              <ul className="space-y-1">
                {hosts.map((host) => {
                  const silent = p.silent_servers.includes(host)
                  return (
                    <li
                      key={host}
                      className="flex items-center gap-2 font-mono text-xs"
                    >
                      <span
                        className={cn(
                          "size-2 shrink-0 rounded-full",
                          silent ? "bg-warning" : "bg-live",
                        )}
                      />
                      <span className="truncate">{host}</span>
                      <span className="text-muted-foreground">
                        {silent ? "silent" : "reporting"}
                      </span>
                    </li>
                  )
                })}
              </ul>
            )}
            <div className="space-y-2">
              <p className="text-muted-foreground text-xs">
                Kamal deploys to hosts by IP or DNS name, and the gem stamps
                records with that host (KAMAL_HOST). Off Kamal, a container
                reports its own hostname, so set RAILWATCH_SERVER to the name
                listed here or the host looks silent.
              </p>
              <pre className="bg-muted overflow-x-auto rounded p-3 font-mono text-xs">
                {SERVER_SNIPPET}
              </pre>
              <p className="text-muted-foreground text-xs">
                Setting <span className="font-mono">RAILWATCH_SERVER</span> in
                the container does the same thing.
              </p>
            </div>
          </CardContent>
        </Card>
      </div>
    </AppLayout>
  )
}
