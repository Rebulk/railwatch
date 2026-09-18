import { router, usePage } from "@inertiajs/react"
import { type PropsWithChildren, useEffect, useState } from "react"

import { AppContent } from "@/components/app-content"
import { AppShell } from "@/components/app-shell"
import { AppSidebar } from "@/components/app-sidebar"
import { AppSidebarHeader } from "@/components/app-sidebar-header"
import { CommandPalette } from "@/components/railwatch/command-palette"
import { ShortcutsDialog } from "@/components/railwatch/shortcuts-dialog"
import { useHotkeys } from "@/hooks/use-hotkeys"
import {
  applicationEnvironmentJobsPath,
  applicationEnvironmentOverviewPath,
  applicationEnvironmentQueriesPath,
  applicationEnvironmentRequestsPath,
  dashboardPath,
  issuesPath,
} from "@/routes"
import type { BreadcrumbItem, SharedProps } from "@/types"

export default function AppSidebarLayout({
  children,
  breadcrumbs = [],
}: PropsWithChildren<{
  breadcrumbs?: BreadcrumbItem[]
}>) {
  const [paletteOpen, setPaletteOpen] = useState(false)
  const [shortcutsOpen, setShortcutsOpen] = useState(false)
  const { environment, window } = usePage<SharedProps>().props

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "k" && (event.metaKey || event.ctrlKey)) {
        event.preventDefault()
        setPaletteOpen((open) => !open)
      }
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [])

  // "g" then a letter jumps to the current environment's Overview/Requests/
  // Jobs/Queries/Issues when a page has one loaded (env-scoped pages share
  // it via EnvironmentScoped); otherwise "g i" falls back to global issues.
  useHotkeys({
    "?": () => setShortcutsOpen((open) => !open),
    "g d": () => router.visit(dashboardPath()),
    "g i": () =>
      router.visit(
        environment
          ? issuesPath({
              application_id: environment.application_id,
              environment_id: environment.id,
            })
          : issuesPath(),
      ),
    ...(environment && {
      "g o": () =>
        router.visit(
          applicationEnvironmentOverviewPath(
            environment.application_id,
            environment.id,
            { window },
          ),
        ),
      "g r": () =>
        router.visit(
          applicationEnvironmentRequestsPath(
            environment.application_id,
            environment.id,
            { window },
          ),
        ),
      "g j": () =>
        router.visit(
          applicationEnvironmentJobsPath(
            environment.application_id,
            environment.id,
            { window },
          ),
        ),
      "g q": () =>
        router.visit(
          applicationEnvironmentQueriesPath(
            environment.application_id,
            environment.id,
            { window },
          ),
        ),
    }),
  })

  return (
    <AppShell variant="sidebar">
      <AppSidebar />
      <AppContent variant="sidebar" className="overflow-x-hidden">
        <AppSidebarHeader
          breadcrumbs={breadcrumbs}
          onOpenCommandPalette={() => setPaletteOpen(true)}
        />
        {children}
      </AppContent>
      <CommandPalette open={paletteOpen} onOpenChange={setPaletteOpen} />
      <ShortcutsDialog open={shortcutsOpen} onOpenChange={setShortcutsOpen} />
    </AppShell>
  )
}
