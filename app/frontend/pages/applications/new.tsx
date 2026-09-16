import { Form, Head } from "@inertiajs/react"

import InputError from "@/components/input-error"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import AppLayout from "@/layouts/app-layout"
import * as R from "@/routes"

export default function NewApplication() {
  return (
    <AppLayout
      breadcrumbs={[{ title: "New application", href: R.newApplicationPath() }]}
    >
      <Head title="Add application" />
      <div className="mx-auto w-full max-w-md p-6">
        <Card>
          <CardHeader>
            <CardTitle>Add an application</CardTitle>
          </CardHeader>
          <CardContent>
            <Form
              method="post"
              action={R.applicationsPath()}
              className="space-y-4"
            >
              {({ errors, processing }) => (
                <>
                  <div className="grid gap-2">
                    <Label htmlFor="name">Name</Label>
                    <Input
                      id="name"
                      name="name"
                      required
                      autoFocus
                      placeholder="Volume Tracker"
                    />
                    <InputError messages={errors.name} />
                  </div>
                  <div className="grid gap-2">
                    <Label htmlFor="issue_prefix">Issue prefix</Label>
                    <Input
                      id="issue_prefix"
                      name="issue_prefix"
                      placeholder="VT"
                      maxLength={8}
                      className="uppercase"
                    />
                    <InputError messages={errors.issue_prefix} />
                    <p className="text-muted-foreground text-xs">
                      Issues get ids like VT-171. Defaults from the name.
                    </p>
                  </div>
                  <div className="grid gap-2">
                    <Label htmlFor="repository_url">Repository URL</Label>
                    <Input
                      id="repository_url"
                      name="repository_url"
                      placeholder="https://github.com/org/repo"
                    />
                    <InputError messages={errors.repository_url} />
                  </div>
                  <div className="grid gap-2">
                    <Label htmlFor="default_branch">Default branch</Label>
                    <Input
                      id="default_branch"
                      name="default_branch"
                      defaultValue="main"
                    />
                    <InputError messages={errors.default_branch} />
                    <p className="text-muted-foreground text-xs">
                      Stack frames link into this repository at the
                      deploy&apos;s git SHA when one was recorded, and at this
                      branch otherwise.
                    </p>
                  </div>
                  <div className="grid gap-2">
                    <Label htmlFor="environment_name">First environment</Label>
                    <Input
                      id="environment_name"
                      name="environment_name"
                      defaultValue="production"
                    />
                  </div>
                  <Button disabled={processing}>Create application</Button>
                </>
              )}
            </Form>
          </CardContent>
        </Card>
      </div>
    </AppLayout>
  )
}
