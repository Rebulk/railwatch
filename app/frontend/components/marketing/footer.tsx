import { Link } from "@inertiajs/react"

import AppWordmark from "@/components/app-wordmark"
import { docPath, docsPath } from "@/routes"

import { RebulkWordmark } from "./rebulk-wordmark"

export function MarketingFooter() {
  return (
    <footer className="mx-auto flex w-full max-w-5xl flex-col gap-3 border-t px-6 py-8 text-sm sm:flex-row sm:items-center sm:justify-between">
      <div className="flex items-center text-white">
        <AppWordmark className="h-4 w-auto" />
      </div>
      <p className="text-muted-foreground flex flex-wrap items-center gap-x-2 gap-y-1">
        <Link href={docsPath()} className="hover:text-foreground">
          Docs
        </Link>
        <span aria-hidden>·</span>
        <Link
          href={docPath("legal", "terms")}
          className="hover:text-foreground"
        >
          Terms
        </Link>
        <span aria-hidden>·</span>
        <Link
          href={docPath("legal", "privacy")}
          className="hover:text-foreground"
        >
          Privacy
        </Link>
        <span aria-hidden>·</span>
        <span className="flex items-baseline gap-1.5">
          Built by
          <a
            href="https://rebulk.com"
            className="text-foreground/80 hover:text-foreground transition-colors"
          >
            <RebulkWordmark className="h-3 w-auto" />
          </a>
        </span>
        <span aria-hidden>·</span>© {new Date().getFullYear()}
      </p>
    </footer>
  )
}
