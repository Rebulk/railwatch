import { Head, usePage } from "@inertiajs/react"
import type { ReactNode } from "react"

import AppLayout from "@/layouts/app-layout"
import { applicationEnvironmentOverviewPath, applicationPath } from "@/routes"
import type { BreadcrumbItem, SharedProps } from "@/types"

// Layout for every environment-scoped telemetry page: breadcrumbs from the
// shared environment prop, page title, and consistent padding.
export default function EnvLayout({
  title,
  children,
  crumbs = [],
}: {
  title: string
  children: ReactNode
  crumbs?: BreadcrumbItem[]
}) {
  const { environment } = usePage<SharedProps>().props
  const base: BreadcrumbItem[] = environment
    ? [
        {
          title: environment.application_name,
          href: applicationPath(environment.application_id),
        },
        {
          title: environment.name,
          href: applicationEnvironmentOverviewPath(
            environment.application_id,
            environment.id,
          ),
        },
      ]
    : []
  const breadcrumbs = [
    ...base,
    ...(crumbs.length ? crumbs : [{ title, href: "#" }]),
  ]
  return (
    <AppLayout breadcrumbs={breadcrumbs}>
      <Head
        title={
          environment
            ? `${title} · ${environment.application_name} ${environment.name}`
            : title
        }
      />
      <div className="flex flex-1 flex-col gap-4 p-3 md:gap-5 md:p-6">
        {children}
      </div>
    </AppLayout>
  )
}
