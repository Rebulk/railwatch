import { Form, Head, router } from "@inertiajs/react"

import InputError from "@/components/input-error"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import AppLayout from "@/layouts/app-layout"
import * as R from "@/routes"

export default function EditApplication(p: {
  application: {
    id: number
    name: string
    issue_prefix: string
    repository_url: string | null
    default_branch: string
  }
  auto_resolve_after_days: number | null
}) {
  const app = p.application
  return (
    <AppLayout
      breadcrumbs={[
        { title: app.name, href: R.applicationPath(app.id) },
        { title: "Edit", href: "#" },
      ]}
    >
      <Head title={`Edit ${app.name}`} />
      <div className="mx-auto w-full max-w-md space-y-4 p-6">
        <Card>
          <CardHeader>
            <CardTitle>Edit application</CardTitle>
          </CardHeader>
          <CardContent>
            <Form
              method="patch"
              action={R.applicationPath(app.id)}
              className="space-y-4"
            >
              {({ errors, processing }) => (
                <>
                  <div className="grid gap-2">
                    <Label htmlFor="name">Name</Label>
                    <Input
                      id="name"
                      name="name"
                      defaultValue={app.name}
                      required
                    />
                    <InputError messages={errors.name} />
                  </div>
                  <div className="grid gap-2">
                    <Label htmlFor="issue_prefix">Issue prefix</Label>
                    <Input
                      id="issue_prefix"
                      name="issue_prefix"
                      defaultValue={app.issue_prefix}
                      maxLength={8}
                    />
                    <InputError messages={errors.issue_prefix} />
                  </div>
                  <div className="grid gap-2">
                    <Label htmlFor="repository_url">Repository URL</Label>
                    <Input
                      id="repository_url"
                      name="repository_url"
                      defaultValue={app.repository_url ?? ""}
                      placeholder="https://github.com/org/repo"
                    />
                    <InputError messages={errors.repository_url} />
                  </div>
                  <div className="grid gap-2">
                    <Label htmlFor="default_branch">Default branch</Label>
                    <Input
                      id="default_branch"
                      name="default_branch"
                      defaultValue={app.default_branch}
                    />
                    <InputError messages={errors.default_branch} />
                    <p className="text-muted-foreground text-xs">
                      Stack frames link into this repository at the
                      deploy&apos;s git SHA when one was recorded, and at this
                      branch otherwise.
                    </p>
                  </div>
                  <div className="grid gap-2">
                    <Label htmlFor="auto_resolve_after_days">
                      Auto-resolve issues
                    </Label>
                    <select
                      id="auto_resolve_after_days"
                      name="auto_resolve_after_days"
                      defaultValue={p.auto_resolve_after_days ?? ""}
                      className="border-input bg-background h-9 rounded-md border px-3 text-sm"
                    >
                      <option value="">Never</option>
                      <option value="7">
                        After 7 days without a recurrence
                      </option>
                      <option value="14">
                        After 14 days without a recurrence
                      </option>
                      <option value="30">
                        After 30 days without a recurrence
                      </option>
                    </select>
                    <p className="text-muted-foreground text-xs">
                      Applies to every application in this account.
                    </p>
                  </div>
                  <Button disabled={processing}>Save</Button>
                </>
              )}
            </Form>
          </CardContent>
        </Card>
        <Card className="border-destructive/40">
          <CardHeader>
            <CardTitle>Danger zone</CardTitle>
          </CardHeader>
          <CardContent>
            <Button
              variant="destructive"
              size="sm"
              onClick={() =>
                confirm(
                  "Delete this application, its environments, telemetry, and issues?",
                ) && router.delete(R.applicationPath(app.id))
              }
            >
              Delete application
            </Button>
          </CardContent>
        </Card>
      </div>
    </AppLayout>
  )
}
