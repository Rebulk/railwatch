import { Form, Head } from "@inertiajs/react"

import InputError from "@/components/input-error"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import AppLayout from "@/layouts/app-layout"
import * as R from "@/routes"

export default function NewAccount() {
  return (
    <AppLayout
      breadcrumbs={[{ title: "New account", href: R.newAccountPath() }]}
    >
      <Head title="Create your account" />
      <div className="mx-auto w-full max-w-md p-6">
        <Card>
          <CardHeader>
            <CardTitle>Create your Railwatch account</CardTitle>
          </CardHeader>
          <CardContent>
            <Form method="post" action={R.accountsPath()} className="space-y-4">
              {({ errors, processing }) => (
                <>
                  <div className="grid gap-2">
                    <Label htmlFor="name">Organization name</Label>
                    <Input
                      id="name"
                      name="name"
                      required
                      autoFocus
                      placeholder="Rebulk"
                    />
                    <InputError messages={errors.name} />
                  </div>
                  <Button disabled={processing}>Create account</Button>
                </>
              )}
            </Form>
          </CardContent>
        </Card>
      </div>
    </AppLayout>
  )
}
