import { router, usePage } from "@inertiajs/react"
import { AlertOctagon, LayoutGrid, Plug, SearchIcon, Users } from "lucide-react"
import { useState } from "react"

import {
  CommandDialog,
  CommandEmpty,
  CommandGroup,
  CommandInput,
  CommandItem,
  CommandList,
  CommandSeparator,
} from "@/components/ui/command"
import { envPages } from "@/lib/env-pages"
import {
  applicationEnvironmentOverviewPath,
  dashboardPath,
  issuesPath,
  settingsIntegrationsPath,
  settingsMembersPath,
} from "@/routes"
import type { NavItem, SharedProps } from "@/types"

const staticNav = (embedded: boolean): NavItem[] => [
  ...(embedded
    ? []
    : [{ title: "Dashboard", href: dashboardPath(), icon: LayoutGrid }]),
  { title: "Issues", href: issuesPath(), icon: AlertOctagon },
  ...(embedded
    ? []
    : [
        { title: "Integrations", href: settingsIntegrationsPath(), icon: Plug },
        { title: "Members", href: settingsMembersPath(), icon: Users },
      ]),
]

export function CommandPalette({
  open,
  onOpenChange,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
}) {
  const [query, setQuery] = useState("")
  const {
    applications,
    environment,
    embedded,
    window: currentWindow,
  } = usePage<SharedProps>().props

  const go = (href: string) => {
    onOpenChange(false)
    router.visit(href)
  }

  const envItems = environment
    ? envPages(
        environment.application_id,
        environment.id,
        currentWindow ?? "24h",
      )
    : []

  return (
    <CommandDialog open={open} onOpenChange={onOpenChange}>
      <CommandInput
        placeholder="Search pages, applications, issues…"
        value={query}
        onValueChange={setQuery}
      />
      <CommandList>
        <CommandEmpty>No results found.</CommandEmpty>
        <CommandGroup heading="Navigation">
          {staticNav(!!embedded).map((item) => (
            <CommandItem key={item.title} onSelect={() => go(item.href)}>
              {item.icon && <item.icon />}
              <span>{item.title}</span>
            </CommandItem>
          ))}
        </CommandGroup>
        {envItems.length > 0 && (
          <CommandGroup
            heading={`${environment!.application_name} · ${environment!.name}`}
          >
            {envItems.map((item) => (
              <CommandItem key={item.title} onSelect={() => go(item.href)}>
                {item.icon && <item.icon />}
                <span>{item.title}</span>
              </CommandItem>
            ))}
          </CommandGroup>
        )}
        {!embedded && (
          <CommandGroup heading="Applications">
            {applications.flatMap((app) =>
              app.environments.map((env) => (
                <CommandItem
                  key={`${app.id}-${env.id}`}
                  value={`${app.name} ${env.name}`}
                  onSelect={() =>
                    go(applicationEnvironmentOverviewPath(app.id, env.id))
                  }
                >
                  <span>
                    {app.name} · {env.name}
                  </span>
                </CommandItem>
              )),
            )}
          </CommandGroup>
        )}
        {query.trim() && (
          <>
            <CommandSeparator />
            <CommandGroup heading="Search">
              <CommandItem
                value={query}
                onSelect={() =>
                  go(`${issuesPath()}?q=${encodeURIComponent(query)}`)
                }
              >
                <SearchIcon />
                <span>Search issues for &ldquo;{query}&rdquo;</span>
              </CommandItem>
            </CommandGroup>
          </>
        )}
      </CommandList>
    </CommandDialog>
  )
}
