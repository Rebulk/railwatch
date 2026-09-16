import { Form, Head } from "@inertiajs/react"

import InputError from "@/components/input-error"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import AppLayout from "@/layouts/app-layout"
import * as R from "@/routes"

export default function NewEnvironment(p: {
  application: { id: number; name: string }
}) {
  return (
    <AppLayout
      breadcrumbs={[
        {
          title: p.application.name,
          href: R.applicationPath(p.application.id),
        },
        { title: "New environment", href: "#" },
      ]}
    >
      <Head title="Add environment" />
      <div className="mx-auto w-full max-w-md p-6">
        <Card>
          <CardHeader>
            <CardTitle>Add environment to {p.application.name}</CardTitle>
          </CardHeader>
          <CardContent>
            <Form
              method="post"
              action={R.applicationEnvironmentsPath(p.application.id)}
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
                      placeholder="staging"
                      pattern="[a-z0-9_-]+"
                    />
                    <InputError messages={errors.name} />
                    <p className="text-muted-foreground text-xs">
                      Lowercase letters, numbers, dashes. Each environment gets
                      its own token and database.
                    </p>
                  </div>
                  <Button disabled={processing}>Create environment</Button>
                </>
              )}
            </Form>
          </CardContent>
        </Card>
      </div>
    </AppLayout>
  )
}
