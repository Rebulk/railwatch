import { Form, Head, router, usePage } from "@inertiajs/react"

import { GoogleSignInButton } from "@/components/google-sign-in-button"
import InputError from "@/components/input-error"
import { DataTable } from "@/components/railwatch/data-table"
import { Badge } from "@/components/ui/badge"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import AppLayout from "@/layouts/app-layout"
import { ago } from "@/lib/format"
import * as R from "@/routes"

interface Member {
  id: number
  name: string
  email: string
  role: string
  user_id: number
}

interface PendingInvitation {
  id: number
  email: string
  role: string
  expires_at: string
}

export default function Members(p: {
  members: Member[]
  invitations: PendingInvitation[]
  roles: string[]
  ownership: {
    current_user_id: number
    can_transfer: boolean
    can_delete_account: boolean
  }
}) {
  const { account, auth } = usePage().props

  return (
    <AppLayout
      breadcrumbs={[{ title: "Members", href: R.settingsMembersPath() }]}
    >
      <Head title="Members" />
      <div className="flex flex-1 flex-col gap-6 p-4 md:p-6">
        <div>
          <h1 className="text-xl font-semibold">Members</h1>
          <p className="text-muted-foreground text-sm">
            People who can see this account&apos;s applications and issues.
          </p>
        </div>
        <Card className="max-w-lg">
          <CardHeader>
            <CardTitle className="text-sm">Add member</CardTitle>
          </CardHeader>
          <CardContent>
            <Form
              method="post"
              action={R.settingsMembersPath()}
              className="flex flex-wrap items-end gap-3"
              resetOnSuccess
            >
              {({ errors, processing }) => (
                <>
                  <div className="grid flex-1 gap-1">
                    <Label htmlFor="email">Email</Label>
                    <Input id="email" name="email" type="email" required />
                    <InputError messages={errors.email} />
                  </div>
                  <div className="grid gap-1">
                    <Label htmlFor="role">Role</Label>
                    <select
                      id="role"
                      name="role"
                      className="border-input h-9 rounded-md border bg-transparent px-2 text-sm"
                    >
                      {p.roles
                        .filter((r) => r !== "owner")
                        .map((r) => (
                          <option key={r} value={r}>
                            {r}
                          </option>
                        ))}
                    </select>
                  </div>
                  <Button disabled={processing}>Invite</Button>
                </>
              )}
            </Form>
          </CardContent>
        </Card>
        {p.invitations.length > 0 && (
          <Card>
            <CardHeader>
              <CardTitle>Pending invitations</CardTitle>
            </CardHeader>
            <CardContent>
              <DataTable
                rows={p.invitations}
                rowKey={(i) => i.id}
                columns={[
                  {
                    key: "e",
                    header: "Email",
                    cell: (i) => (
                      <span className="font-mono text-xs">{i.email}</span>
                    ),
                  },
                  {
                    key: "r",
                    header: "Role",
                    cell: (i) => <Badge variant="outline">{i.role}</Badge>,
                  },
                  {
                    key: "x",
                    header: "Expires",
                    cell: (i) => (
                      <span className="text-muted-foreground text-xs">
                        {ago(i.expires_at)}
                      </span>
                    ),
                  },
                  {
                    key: "a",
                    header: "",
                    align: "right",
                    cell: (i) => (
                      <span className="flex justify-end gap-1">
                        <Button
                          size="sm"
                          variant="ghost"
                          onClick={() =>
                            router.post(R.resendSettingsInvitationPath(i.id))
                          }
                        >
                          Resend
                        </Button>
                        <Button
                          size="sm"
                          variant="ghost"
                          className="text-destructive"
                          onClick={() =>
                            router.delete(R.settingsInvitationPath(i.id))
                          }
                        >
                          Withdraw
                        </Button>
                      </span>
                    ),
                  },
                ]}
              />
            </CardContent>
          </Card>
        )}
        <DataTable
          rows={p.members}
          rowKey={(m) => m.id}
          columns={[
            { key: "n", header: "Name", cell: (m) => m.name },
            {
              key: "e",
              header: "Email",
              cell: (m) => <span className="font-mono text-xs">{m.email}</span>,
            },
            {
              key: "r",
              header: "Role",
              cell: (m) =>
                m.role === "owner" ? (
                  <Badge variant="outline">owner</Badge>
                ) : (
                  <select
                    value={m.role}
                    aria-label={`Role for ${m.name}`}
                    onChange={(ev) =>
                      router.patch(R.settingsMemberPath(m.id), {
                        role: ev.target.value,
                      })
                    }
                    className="border-input bg-background h-7 rounded-md border px-2 text-xs"
                  >
                    {p.roles
                      .filter((r) => r !== "owner")
                      .map((r) => (
                        <option key={r} value={r}>
                          {r}
                        </option>
                      ))}
                  </select>
                ),
            },
            {
              key: "x",
              header: "",
              align: "right",
              cell: (m) => (
                <span className="flex justify-end gap-1">
                  {p.ownership.can_transfer &&
                    m.user_id !== p.ownership.current_user_id && (
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => {
                          if (
                            window.confirm(
                              `Transfer ownership to ${m.name}? Your role will become admin.`,
                            )
                          ) {
                            router.post(
                              R.transferOwnershipSettingsMemberPath(m.id),
                            )
                          }
                        }}
                      >
                        Transfer ownership
                      </Button>
                    )}
                  {m.role !== "owner" && (
                    <Button
                      size="sm"
                      variant="ghost"
                      className="text-destructive"
                      onClick={() => router.delete(R.settingsMemberPath(m.id))}
                    >
                      Remove
                    </Button>
                  )}
                </span>
              ),
            },
          ]}
        />
        {p.ownership.can_delete_account && account && (
          <Card className="border-destructive/30 max-w-lg">
            <CardHeader>
              <CardTitle className="text-destructive text-sm">
                Delete account
              </CardTitle>
            </CardHeader>
            <CardContent className="space-y-4">
              <p className="text-muted-foreground text-sm">
                Permanently deletes {account.name}, its applications, ingest
                tokens, alerts, and telemetry databases. This cannot be undone.
              </p>
              {auth.user.provider && !auth.session.recently_authenticated && (
                <GoogleSignInButton
                  label="Confirm with Google"
                  reauthenticateFor="account"
                  separated={false}
                />
              )}
              <Form
                method="delete"
                action={R.accountPath(account.id)}
                className="grid gap-3"
              >
                {({ errors, processing }) => (
                  <>
                    <div className="grid gap-1">
                      <Label htmlFor="account-deletion-confirmation">
                        Enter {account.name} to confirm
                      </Label>
                      <Input
                        id="account-deletion-confirmation"
                        name="confirmation"
                        autoComplete="off"
                      />
                      <InputError messages={errors.confirmation} />
                    </div>
                    {!auth.user.provider && (
                      <div className="grid gap-1">
                        <Label htmlFor="account-password-challenge">
                          Current password
                        </Label>
                        <Input
                          id="account-password-challenge"
                          type="password"
                          name="password_challenge"
                          autoComplete="current-password"
                        />
                        <InputError messages={errors.password_challenge} />
                      </div>
                    )}
                    <Button
                      variant="destructive"
                      className="w-fit"
                      disabled={
                        processing ||
                        (Boolean(auth.user.provider) &&
                          !auth.session.recently_authenticated)
                      }
                    >
                      Delete account and telemetry
                    </Button>
                  </>
                )}
              </Form>
            </CardContent>
          </Card>
        )}
      </div>
    </AppLayout>
  )
}
