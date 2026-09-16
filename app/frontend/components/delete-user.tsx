import { Form } from "@inertiajs/react"
import { useRef } from "react"

import { GoogleSignInButton } from "@/components/google-sign-in-button"
import HeadingSmall from "@/components/heading-small"
import InputError from "@/components/input-error"
import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogClose,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { usersPath } from "@/routes"

export default function DeleteUser({
  blockingAccounts,
  provider,
  recentlyAuthenticated,
  email,
}: {
  blockingAccounts: { id: number; name: string }[]
  provider: string | null
  recentlyAuthenticated: boolean
  email: string
}) {
  const passwordInput = useRef<HTMLInputElement>(null)

  return (
    <div className="space-y-6">
      <HeadingSmall
        title="Delete user"
        description="Delete your login and personal settings. Shared account data stays with its remaining owners."
      />
      <div className="space-y-4 rounded-lg border border-red-100 bg-red-50 p-4 dark:border-red-200/10 dark:bg-red-700/10">
        <div className="relative space-y-0.5 text-red-600 dark:text-red-100">
          <p className="font-medium">Warning</p>
          <p className="text-sm">
            Please proceed with caution, this cannot be undone.
          </p>
        </div>

        <Dialog>
          <DialogTrigger asChild>
            <Button variant="destructive">Delete user</Button>
          </DialogTrigger>
          <DialogContent>
            <DialogTitle>
              Are you sure you want to delete your user?
            </DialogTitle>
            <DialogDescription>
              This deletes your login, sessions, and personal settings. It does
              not delete shared accounts or their telemetry. Transfer or delete
              every account you solely own first.
            </DialogDescription>
            {blockingAccounts.length > 0 && (
              <div className="border-destructive/30 bg-destructive/5 rounded-md border p-3 text-sm">
                Transfer or delete these accounts first:{" "}
                {blockingAccounts.map((account) => account.name).join(", ")}.
              </div>
            )}
            {provider && !recentlyAuthenticated && (
              <GoogleSignInButton
                label="Confirm with Google"
                reauthenticateFor="user"
                separated={false}
              />
            )}
            <Form
              method="delete"
              action={usersPath()}
              options={{
                preserveScroll: true,
              }}
              onError={() => passwordInput.current?.focus()}
              resetOnSuccess
              className="space-y-6"
            >
              {({ resetAndClearErrors, processing, errors }) => (
                <>
                  {provider ? (
                    <div className="grid gap-2">
                      <Label htmlFor="user-deletion-confirmation">
                        Enter your email to confirm
                      </Label>
                      <Input
                        id="user-deletion-confirmation"
                        name="confirmation"
                        placeholder={email}
                        autoComplete="off"
                      />
                      <InputError messages={errors.password_challenge} />
                    </div>
                  ) : (
                    <div className="grid gap-2">
                      <Label htmlFor="password_challenge" className="sr-only">
                        Password
                      </Label>

                      <Input
                        id="password_challenge"
                        type="password"
                        name="password_challenge"
                        ref={passwordInput}
                        placeholder="Password"
                        autoComplete="current-password"
                      />

                      <InputError messages={errors.password_challenge} />
                    </div>
                  )}

                  <InputError messages={errors.account_ownership} />

                  <DialogFooter>
                    <DialogClose asChild>
                      <Button
                        variant="secondary"
                        onClick={() => resetAndClearErrors()}
                      >
                        Cancel
                      </Button>
                    </DialogClose>

                    <Button
                      variant="destructive"
                      disabled={
                        processing ||
                        blockingAccounts.length > 0 ||
                        (Boolean(provider) && !recentlyAuthenticated)
                      }
                      asChild
                    >
                      <button type="submit">Delete user</button>
                    </Button>
                  </DialogFooter>
                </>
              )}
            </Form>
          </DialogContent>
        </Dialog>
      </div>
    </div>
  )
}
