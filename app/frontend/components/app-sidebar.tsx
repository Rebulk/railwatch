import { Link, usePage } from "@inertiajs/react"
import {
  AlertOctagon,
  BellRing,
  BookOpen,
  LayoutGrid,
  Plug,
  Users,
} from "lucide-react"

import { NavFooter } from "@/components/nav-footer"
import { NavMain } from "@/components/nav-main"
import { NavUser } from "@/components/nav-user"
import { EnvNav } from "@/components/railwatch/env-nav"
import { EnvSwitcher } from "@/components/railwatch/env-switcher"
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar"
import {
  alertsPath,
  dashboardPath,
  issuesPath,
  settingsIntegrationsPath,
  settingsMembersPath,
} from "@/routes"
import type { NavItem, SharedProps } from "@/types"

import AppLogo from "./app-logo"

// Integrations and Members are account features of the hosted platform;
// an embedded install has neither.
const mainNavItems = (embedded: boolean): NavItem[] => [
  ...(embedded
    ? []
    : [{ title: "Dashboard", href: dashboardPath(), icon: LayoutGrid }]),
  { title: "Issues", href: issuesPath(), icon: AlertOctagon },
  { title: "Alerts", href: alertsPath(), icon: BellRing },
  ...(embedded
    ? []
    : [
        { title: "Integrations", href: settingsIntegrationsPath(), icon: Plug },
        { title: "Members", href: settingsMembersPath(), icon: Users },
      ]),
]

const footerNavItems = (embedded: boolean): NavItem[] => [
  {
    title: "Documentation",
    href: embedded ? "https://railwatch.rebulk.com/docs" : "/docs",
    icon: BookOpen,
  },
]

export function AppSidebar() {
  const { environment, applications, embedded } = usePage<SharedProps>().props
  return (
    <Sidebar collapsible="icon" variant="sidebar">
      <SidebarHeader className="border-sidebar-border gap-0 border-b p-1.5">
        {applications.length > 0 ? (
          <EnvSwitcher />
        ) : (
          <SidebarMenu>
            <SidebarMenuItem>
              <SidebarMenuButton size="lg" asChild>
                <Link href={dashboardPath()} prefetch>
                  <AppLogo />
                </Link>
              </SidebarMenuButton>
            </SidebarMenuItem>
          </SidebarMenu>
        )}
      </SidebarHeader>

      <SidebarContent className="gap-0 p-1.5">
        {environment && <EnvNav />}
        <NavMain
          items={mainNavItems(!!embedded)}
          label={environment ? "Account" : ""}
        />
      </SidebarContent>

      <SidebarFooter>
        <NavFooter items={footerNavItems(!!embedded)} className="mt-auto" />
        <NavUser />
      </SidebarFooter>
    </Sidebar>
  )
}
