import type { SVGAttributes } from "react"

import { Button } from "@/components/ui/button"
import { Separator } from "@/components/ui/separator"

function GoogleIcon(props: SVGAttributes<SVGElement>) {
  return (
    <svg viewBox="0 0 24 24" {...props}>
      <path
        d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92a5.06 5.06 0 0 1-2.2 3.32v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.1Z"
        fill="#4285F4"
      />
      <path
        d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.99.66-2.25 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.85A11 11 0 0 0 12 23Z"
        fill="#34A853"
      />
      <path
        d="M5.84 14.09A6.6 6.6 0 0 1 5.5 12c0-.73.13-1.43.34-2.09V7.06H2.18A11 11 0 0 0 1 12c0 1.77.42 3.45 1.18 4.94l3.66-2.85Z"
        fill="#FBBC05"
      />
      <path
        d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1a11 11 0 0 0-9.82 6.06l3.66 2.85C6.71 7.31 9.14 5.38 12 5.38Z"
        fill="#EA4335"
      />
    </svg>
  )
}

function csrfToken() {
  if (typeof document === "undefined") return ""
  return (
    document
      .querySelector('meta[name="csrf-token"]')
      ?.getAttribute("content") ?? ""
  )
}

// A real HTML form, not an Inertia form: the CSRF token has to be a hidden
// field that omniauth-rails_csrf_protection reads, and the browser has to
// actually navigate to /auth/google_oauth2 for OmniAuth's middleware to pick
// up the request (an XHR would just get redirected in place).
export function GoogleSignInButton({
  label,
  reauthenticateFor,
  separated = true,
}: {
  label: string
  reauthenticateFor?: "user" | "account"
  separated?: boolean
}) {
  return (
    <div className="grid gap-6">
      {separated && (
        <div className="relative text-center text-sm">
          <Separator className="absolute top-1/2" />
          <span className="bg-background text-muted-foreground relative px-2">
            Or
          </span>
        </div>
      )}
      <form method="post" action="/auth/google_oauth2">
        <input type="hidden" name="authenticity_token" value={csrfToken()} />
        {reauthenticateFor && (
          <>
            <input
              type="hidden"
              name="reauthenticate"
              value={reauthenticateFor}
            />
            <input type="hidden" name="prompt" value="select_account" />
          </>
        )}
        <Button type="submit" variant="outline" className="w-full">
          <GoogleIcon className="size-4" />
          {label}
        </Button>
      </form>
    </div>
  )
}
