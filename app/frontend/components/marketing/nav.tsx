import { Link } from "@inertiajs/react"

import AppWordmark from "@/components/app-wordmark"
import { Button } from "@/components/ui/button"
import {
  dashboardPath,
  docsPath,
  rootPath,
  signInPath,
  signUpPath,
} from "@/routes"

export function MarketingNav({ signedIn }: { signedIn: boolean }) {
  return (
    <header className="mx-auto flex w-full max-w-5xl items-center justify-between px-6 py-6">
      <Link href={rootPath()} className="flex items-center text-white">
        <AppWordmark className="h-4 w-auto sm:h-5" />
      </Link>
      {signedIn ? (
        <nav className="flex items-center gap-2">
          <Button asChild variant="ghost" size="sm">
            <Link href={docsPath()}>Docs</Link>
          </Button>
          <Button asChild size="sm">
            <Link href={dashboardPath()}>Dashboard</Link>
          </Button>
        </nav>
      ) : (
        <nav className="flex items-center gap-2">
          <Button asChild variant="ghost" size="sm">
            <Link href={docsPath()}>Docs</Link>
          </Button>
          <Button asChild variant="ghost" size="sm">
            <Link href={signInPath()}>Sign in</Link>
          </Button>
          <Button asChild size="sm">
            <Link href={signUpPath()}>Get started</Link>
          </Button>
        </nav>
      )}
    </header>
  )
}
