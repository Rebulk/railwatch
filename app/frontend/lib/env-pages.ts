import {
  Activity,
  AlertTriangle,
  ArrowUpRight,
  Bell,
  BellRing,
  Bug,
  Building2,
  Cable,
  CalendarClock,
  Database,
  FileText,
  Flame,
  Gauge,
  GitCommit,
  HardDrive,
  Layers,
  LayoutTemplate,
  Mail,
  MonitorSmartphone,
  Package,
  PieChart,
  Rocket,
  Server,
  Siren,
  Sparkles,
  Terminal,
  Timer,
  Users,
  Workflow,
} from "lucide-react"

import * as R from "@/routes"
import type { NavItem } from "@/types"

export type EnvPageGroup = "activity" | "monitoring" | "settings"

export interface EnvPage extends NavItem {
  group: EnvPageGroup
}

// Shared list of environment sub-pages, used by the sidebar EnvNav, the
// command palette, and the mobile page switcher so they never drift apart.
// Grouped the way Nightwatch groups its sidebar: Activity (what the app
// did), Monitoring (people, deploys, health), Settings (per-environment).
export function envPages(
  applicationId: number,
  environmentId: number,
  window: string,
): EnvPage[] {
  const a = applicationId
  const e = environmentId
  const w = { window }
  return [
    {
      title: "Overview",
      href: R.applicationEnvironmentOverviewPath(a, e, w),
      icon: Gauge,
      group: "activity",
    },
    {
      title: "Requests",
      href: R.applicationEnvironmentRequestsPath(a, e, w),
      icon: Activity,
      group: "activity",
    },
    {
      title: "Jobs",
      href: R.applicationEnvironmentJobsPath(a, e, w),
      icon: Workflow,
      group: "activity",
    },
    {
      title: "Scheduled tasks",
      href: R.applicationEnvironmentScheduledTasksPath(a, e, w),
      icon: CalendarClock,
      group: "activity",
    },
    {
      title: "Commands",
      href: R.applicationEnvironmentCommandsPath(a, e, w),
      icon: Terminal,
      group: "activity",
    },
    {
      title: "Exceptions",
      href: R.applicationEnvironmentExceptionsPath(a, e, w),
      icon: Bug,
      group: "activity",
    },
    {
      title: "Queries",
      href: R.applicationEnvironmentQueriesPath(a, e, w),
      icon: Database,
      group: "activity",
    },
    {
      title: "Spans",
      href: R.applicationEnvironmentSpansPath(a, e, w),
      icon: Timer,
      group: "activity",
    },
    {
      title: "Profiles",
      href: R.applicationEnvironmentProfilesPath(a, e, w),
      icon: Flame,
      group: "activity",
    },
    {
      title: "Transactions",
      href: R.applicationEnvironmentTransactionsPath(a, e, w),
      icon: GitCommit,
      group: "activity",
    },
    {
      title: "View renders",
      href: R.applicationEnvironmentViewRendersPath(a, e, w),
      icon: LayoutTemplate,
      group: "activity",
    },
    {
      title: "Cache",
      href: R.applicationEnvironmentCacheEventsPath(a, e, w),
      icon: Layers,
      group: "activity",
    },
    {
      title: "Mail",
      href: R.applicationEnvironmentMailsPath(a, e, w),
      icon: Mail,
      group: "activity",
    },
    {
      title: "Notifications",
      href: R.applicationEnvironmentNotificationsPath(a, e, w),
      icon: BellRing,
      group: "activity",
    },
    {
      title: "Broadcasts",
      href: R.applicationEnvironmentBroadcastsPath(a, e, w),
      icon: Cable,
      group: "activity",
    },
    {
      title: "Outgoing requests",
      href: R.applicationEnvironmentOutgoingRequestsPath(a, e, w),
      icon: ArrowUpRight,
      group: "activity",
    },
    {
      title: "LLM",
      href: R.applicationEnvironmentLlmCallsPath(a, e, w),
      icon: Sparkles,
      group: "activity",
    },
    {
      title: "Storage",
      href: R.applicationEnvironmentStorageOpsPath(a, e, w),
      icon: HardDrive,
      group: "activity",
    },
    {
      title: "Logs",
      href: R.applicationEnvironmentLogsPath(a, e, w),
      icon: FileText,
      group: "activity",
    },
    {
      title: "Deprecations",
      href: R.applicationEnvironmentDeprecationsPath(a, e, w),
      icon: AlertTriangle,
      group: "activity",
    },
    {
      title: "Visits",
      href: R.applicationEnvironmentVisitsPath(a, e, w),
      icon: MonitorSmartphone,
      group: "monitoring",
    },
    {
      title: "Users",
      href: R.applicationEnvironmentPeoplePath(a, e, w),
      icon: Users,
      group: "monitoring",
    },
    {
      title: "Tenants",
      href: R.applicationEnvironmentTenantsPath(a, e, w),
      icon: Building2,
      group: "monitoring",
    },
    {
      title: "Deploys",
      href: R.applicationEnvironmentDeploysPath(a, e),
      icon: Rocket,
      group: "monitoring",
    },
    {
      title: "Releases",
      href: R.applicationEnvironmentReleasesPath(a, e, w),
      icon: Package,
      group: "monitoring",
    },
    {
      title: "Processes",
      href: R.applicationEnvironmentProcessesPath(a, e),
      icon: Server,
      group: "monitoring",
    },
    {
      title: "Alerts",
      href: R.applicationEnvironmentAlertsPath(a, e),
      icon: Siren,
      group: "monitoring",
    },
    {
      title: "Thresholds",
      href: R.applicationEnvironmentThresholdsPath(a, e),
      icon: Bell,
      group: "settings",
    },
    {
      title: "Usage",
      href: R.applicationEnvironmentUsagePath(a, e),
      icon: PieChart,
      group: "settings",
    },
  ]
}

export const ENV_PAGE_GROUPS: { key: EnvPageGroup; title: string }[] = [
  { key: "activity", title: "Activity" },
  { key: "monitoring", title: "Monitoring" },
  { key: "settings", title: "Settings" },
]
