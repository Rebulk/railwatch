import { Transition } from "@headlessui/react"
import { Form, Head, router, usePage } from "@inertiajs/react"
import { useState } from "react"

import DeleteUser from "@/components/delete-user"
import HeadingSmall from "@/components/heading-small"
import InputError from "@/components/input-error"
import { CopyBlock } from "@/components/railwatch/copy-block"
import { McpSetup } from "@/components/railwatch/mcp-setup"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import AppLayout from "@/layouts/app-layout"
import SettingsLayout from "@/layouts/settings/layout"
import {
  generateMcpTokenSettingsProfilePath,
  revokeMcpTokenSettingsProfilePath,
  settingsProfilePath,
} from "@/routes"
import type { BreadcrumbItem } from "@/types"

const breadcrumbs: BreadcrumbItem[] = [
  {
    title: "Profile settings",
    href: settingsProfilePath(),
  },
]

interface Props {
  weekly_digest: boolean
  mcp_token: string | null
  api_tokens: {
    id: number
    name: string
    scopes: string[]
    restriction: string
    expires_at: string | null
    last_used_at: string | null
    revoked_at: string | null
    created_at: string
  }[]
  token_targets: { value: string; label: string }[]
  token_scopes: string[]
  mcp_url: string
  deletion: {
    blocking_accounts: { id: number; name: string }[]
  }
}

const editors = [
  { value: "github", label: "GitHub" },
  { value: "gitlab", label: "GitLab" },
  { value: "vscode", label: "VS Code" },
  { value: "cursor", label: "Cursor" },
  { value: "zed", label: "Zed" },
  { value: "rubymine", label: "RubyMine" },
  { value: "textmate", label: "TextMate" },
]

// The editors that open a local file over a URL scheme, and so need to know
// where this machine keeps its checkout.
const localEditors = ["vscode", "cursor", "zed", "rubymine", "textmate"]

export default function Profile(p: Props) {
  const { auth } = usePage().props
  const [editor, setEditor] = useState(auth.user.editor)

  return (
    <AppLayout breadcrumbs={breadcrumbs}>
      <Head title={breadcrumbs[breadcrumbs.length - 1].title} />

      <SettingsLayout>
        <div className="space-y-6">
          <HeadingSmall
            title="Profile information"
            description="Update your name and where source links open"
          />

          <Form
            method="patch"
            action={settingsProfilePath()}
            options={{
              preserveScroll: true,
            }}
            className="space-y-6"
          >
            {({ errors, processing, recentlySuccessful }) => (
              <>
                <div className="grid gap-2">
                  <Label htmlFor="name">Name</Label>

                  <Input
                    id="name"
                    name="name"
                    className="mt-1 block w-full"
                    defaultValue={auth.user.name}
                    required
                    autoComplete="name"
                    placeholder="Full name"
                  />

                  <InputError className="mt-2" messages={errors.name} />
                </div>

                <div className="grid gap-2">
                  <Label htmlFor="editor">Editor</Label>

                  <select
                    id="editor"
                    name="editor"
                    value={editor}
                    onChange={(e) => setEditor(e.target.value)}
                    className="border-input bg-background h-9 rounded-md border px-3 text-sm"
                  >
                    {editors.map((e) => (
                      <option key={e.value} value={e.value}>
                        {e.label}
                      </option>
                    ))}
                  </select>

                  <InputError className="mt-2" messages={errors.editor} />
                  <span className="text-muted-foreground text-xs">
                    Where a file:line in a stack trace opens — the
                    application&apos;s repository, or this machine&apos;s
                    editor.
                  </span>
                </div>

                {localEditors.includes(editor) && (
                  <div className="grid gap-2">
                    <Label htmlFor="editor_root">Local checkout path</Label>

                    <Input
                      id="editor_root"
                      name="editor_root"
                      className="mt-1 block w-full"
                      defaultValue={auth.user.editor_root ?? ""}
                      placeholder="/Users/you/code/widgets"
                    />

                    <InputError
                      className="mt-2"
                      messages={errors.editor_root}
                    />
                  </div>
                )}

                <label className="flex items-start gap-3 text-sm">
                  <input type="hidden" name="weekly_digest" value="0" />
                  <input
                    type="checkbox"
                    name="weekly_digest"
                    value="1"
                    defaultChecked={p.weekly_digest}
                    className="mt-0.5"
                  />
                  <span>
                    <span className="font-medium">Weekly digest</span>
                    <span className="text-muted-foreground block text-xs">
                      A Monday email with requests, p95, failures, new and
                      resolved issues, and deploys for each account you belong
                      to.
                    </span>
                  </span>
                </label>

                <div className="flex items-center gap-4">
                  <Button disabled={processing}>Save</Button>

                  <Transition
                    show={recentlySuccessful}
                    enter="transition ease-in-out"
                    enterFrom="opacity-0"
                    leave="transition ease-in-out"
                    leaveTo="opacity-0"
                  >
                    <p className="text-sm text-neutral-600">Saved</p>
                  </Transition>
                </div>
              </>
            )}
          </Form>
        </div>

        <div className="space-y-6">
          <HeadingSmall
            title="API & MCP tokens"
            description="Create independently revocable tokens with only the surfaces, actions, and applications each client needs."
          />
          {p.mcp_token && (
            <div className="space-y-2">
              <p className="text-sm">
                Your new API & MCP token (shown once, copy it now):
              </p>
              <CopyBlock code={p.mcp_token} />
            </div>
          )}
          <Form
            method="post"
            action={generateMcpTokenSettingsProfilePath()}
            className="grid gap-4 rounded-md border p-4"
          >
            {({ processing, errors }) => (
              <>
                <div className="grid gap-2">
                  <Label htmlFor="token-name">Token name</Label>
                  <Input
                    id="token-name"
                    name="name"
                    defaultValue="API & MCP token"
                    maxLength={100}
                    required
                  />
                  <InputError messages={errors.name} />
                </div>

                <div className="grid gap-2">
                  <Label htmlFor="token-restriction">Data access</Label>
                  <select
                    id="token-restriction"
                    name="restriction"
                    className="border-input bg-background h-9 rounded-md border px-3 text-sm"
                  >
                    {p.token_targets.map((target) => (
                      <option key={target.value} value={target.value}>
                        {target.label}
                      </option>
                    ))}
                  </select>
                  <InputError messages={errors.restriction} />
                </div>

                <fieldset className="grid gap-2">
                  <legend className="text-sm font-medium">Scopes</legend>
                  <input type="hidden" name="scopes_present" value="1" />
                  <div className="grid grid-cols-2 gap-2">
                    {p.token_scopes.map((scope) => (
                      <label
                        key={scope}
                        className="flex items-center gap-2 text-sm"
                      >
                        <input
                          type="checkbox"
                          name="scopes[]"
                          value={scope}
                          defaultChecked
                        />
                        {scope}
                      </label>
                    ))}
                  </div>
                  <InputError messages={errors.scopes} />
                </fieldset>

                <div className="grid gap-2">
                  <Label htmlFor="token-expiry">Expiry</Label>
                  <select
                    id="token-expiry"
                    name="expires_in_days"
                    className="border-input bg-background h-9 rounded-md border px-3 text-sm"
                    defaultValue="0"
                  >
                    <option value="0">Never</option>
                    <option value="7">7 days</option>
                    <option value="30">30 days</option>
                    <option value="90">90 days</option>
                    <option value="365">1 year</option>
                  </select>
                  <InputError messages={errors.expires_in_days} />
                </div>

                <Button className="w-fit" disabled={processing}>
                  Generate token
                </Button>
              </>
            )}
          </Form>

          <div className="space-y-3">
            {p.api_tokens.length === 0 ? (
              <p className="text-muted-foreground text-sm">
                No API tokens yet.
              </p>
            ) : (
              p.api_tokens.map((token) => (
                <div
                  key={token.id}
                  className="flex items-start justify-between gap-4 rounded-md border p-3"
                >
                  <div className="min-w-0 space-y-1">
                    <p className="font-medium">{token.name}</p>
                    <p className="text-muted-foreground text-xs">
                      {token.scopes.join(", ")} · {token.restriction}
                    </p>
                    <p className="text-muted-foreground text-xs">
                      {token.revoked_at
                        ? `Revoked ${new Date(token.revoked_at).toLocaleString()}`
                        : token.expires_at
                          ? `Expires ${new Date(token.expires_at).toLocaleString()}`
                          : "Never expires"}
                      {token.last_used_at
                        ? ` · Last used ${new Date(token.last_used_at).toLocaleString()}`
                        : " · Never used"}
                    </p>
                  </div>
                  {!token.revoked_at && (
                    <div className="flex shrink-0 gap-2">
                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        onClick={() =>
                          router.post(generateMcpTokenSettingsProfilePath(), {
                            name: token.name,
                            scopes_present: "1",
                            scopes: token.scopes,
                            replace_token_id: token.id,
                          })
                        }
                      >
                        Regenerate
                      </Button>
                      <Button
                        type="button"
                        variant="outline"
                        size="sm"
                        onClick={() =>
                          router.delete(revokeMcpTokenSettingsProfilePath(), {
                            data: { token_id: token.id },
                          })
                        }
                      >
                        Revoke
                      </Button>
                    </div>
                  )}
                </div>
              ))
            )}
          </div>

          <div className="space-y-3 border-t pt-6">
            <div>
              <p className="text-sm font-medium">Connect an assistant</p>
              <p className="text-muted-foreground text-xs">
                {p.mcp_token
                  ? "These blocks already contain the token above. Paste one into your client and restart it."
                  : "Generate a token to get these blocks filled in — until then they carry a placeholder. The same output comes from bin/rails railwatch:mcp in your app."}
              </p>
            </div>
            <McpSetup url={p.mcp_url} token={p.mcp_token} />
          </div>
        </div>

        <DeleteUser
          blockingAccounts={p.deletion.blocking_accounts}
          provider={auth.user.provider}
          recentlyAuthenticated={auth.session.recently_authenticated}
          email={auth.user.email}
        />
      </SettingsLayout>
    </AppLayout>
  )
}
