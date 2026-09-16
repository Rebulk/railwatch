import { Link, router, usePage } from "@inertiajs/react"
import { Check, ChevronsUpDown, Plus } from "lucide-react"

import { LiveDot } from "@/components/railwatch/live-dot"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import {
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar"
import { cn } from "@/lib/utils"
import {
  applicationEnvironmentOverviewPath,
  newApplicationPath,
} from "@/routes"
import type { SharedProps } from "@/types"

function Monogram({ name, className }: { name: string; className?: string }) {
  return (
    <span
      className={cn(
        "bg-muted text-foreground flex size-8 shrink-0 items-center justify-center rounded-md font-mono text-xs font-semibold",
        className,
      )}
    >
      {name.slice(0, 2).toUpperCase()}
    </span>
  )
}

// Application · environment switcher at the top of the sidebar. Mirrors the
// Nightwatch app card: monogram, application name, environment name, and
// a dropdown listing every environment across the account's applications.
export function EnvSwitcher() {
  const { applications, environment, embedded } = usePage<SharedProps>().props
  if (applications.length === 0) return null
  // Account-level pages (dashboard, issues) have no environment; fall back to
  // the first application so the card still names something real.
  const currentApp =
    applications.find((a) => a.id === environment?.application_id) ??
    applications[0]
  // Embedded: one application, one environment, nothing to switch to. The
  // card stays as a header (which app, which environment) with no menu.
  if (embedded) {
    const env = environment ?? currentApp.environments[0]
    return (
      <SidebarMenu>
        <SidebarMenuItem>
          <SidebarMenuButton
            size="lg"
            asChild
            className="border-0 py-2 pr-3 pl-2 hover:bg-transparent"
          >
            <Link
              href={applicationEnvironmentOverviewPath(currentApp.id, env.id)}
              prefetch
            >
              <Monogram name={currentApp.name} />
              <span className="grid flex-1 text-left leading-tight">
                <span className="truncate text-sm font-semibold">
                  {currentApp.name}
                </span>
                <span className="text-muted-foreground truncate text-xs">
                  {env.name}
                </span>
              </span>
            </Link>
          </SidebarMenuButton>
        </SidebarMenuItem>
      </SidebarMenu>
    )
  }
  return (
    <SidebarMenu>
      <SidebarMenuItem>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <SidebarMenuButton
              size="lg"
              className="data-[state=open]:bg-sidebar-accent hover:bg-sidebar-accent border-0 py-2 pr-3 pl-2"
            >
              <Monogram name={currentApp.name} />
              <span className="grid flex-1 text-left leading-tight">
                <span className="truncate text-sm font-semibold">
                  {currentApp.name}
                </span>
                <span className="text-muted-foreground truncate text-xs">
                  {environment
                    ? environment.name
                    : `${currentApp.environments.length} environment${currentApp.environments.length === 1 ? "" : "s"}`}
                </span>
              </span>
              <ChevronsUpDown className="size-3.5 opacity-60" />
            </SidebarMenuButton>
          </DropdownMenuTrigger>
          <DropdownMenuContent
            align="start"
            className="w-(--radix-dropdown-menu-trigger-width) min-w-64"
          >
            {applications.map((app) => (
              <div key={app.id}>
                <DropdownMenuLabel className="label-caps">
                  {app.name}
                </DropdownMenuLabel>
                {app.environments.map((env) => (
                  <DropdownMenuItem
                    key={env.id}
                    onSelect={() =>
                      router.visit(
                        applicationEnvironmentOverviewPath(app.id, env.id),
                      )
                    }
                  >
                    <LiveDot
                      lastSeenAt={env.paused ? null : env.last_seen_at}
                      thresholdMs={10 * 60 * 1000}
                    />
                    <span className="flex-1">{env.name}</span>
                    {env.id === environment?.id && (
                      <Check className="size-3.5" />
                    )}
                  </DropdownMenuItem>
                ))}
              </div>
            ))}
            <DropdownMenuSeparator />
            <DropdownMenuItem
              onSelect={() => router.visit(newApplicationPath())}
            >
              <Plus className="size-3.5" />
              Add application
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
      </SidebarMenuItem>
    </SidebarMenu>
  )
}
