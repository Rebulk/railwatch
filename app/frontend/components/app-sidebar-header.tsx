import { usePage } from "@inertiajs/react"
import { Search } from "lucide-react"

import { Breadcrumbs } from "@/components/breadcrumbs"
import { MobilePageSwitcher } from "@/components/railwatch/mobile-page-switcher"
import { Button } from "@/components/ui/button"
import { SidebarTrigger } from "@/components/ui/sidebar"
import type { BreadcrumbItem as BreadcrumbItemType, SharedProps } from "@/types"

export function AppSidebarHeader({
  breadcrumbs = [],
  onOpenCommandPalette,
}: {
  breadcrumbs?: BreadcrumbItemType[]
  onOpenCommandPalette?: () => void
}) {
  const { environment } = usePage<SharedProps>().props
  return (
    <header className="bg-background/80 sticky top-0 z-20 flex h-12 shrink-0 items-center justify-between gap-2 border-b px-3 backdrop-blur md:h-11 md:border-0 md:bg-transparent md:px-6 md:pt-2 md:backdrop-blur-none">
      <div className="flex min-w-0 items-center gap-2">
        <SidebarTrigger className="text-muted-foreground -ml-1" />
        <div className="text-muted-foreground hidden min-w-0 text-xs md:block">
          <Breadcrumbs breadcrumbs={breadcrumbs} />
        </div>
        {/* On phones the sidebar is a sheet, so the current page name (and a
            quick way to jump between environment pages) lives up here. */}
        <div className="min-w-0 md:hidden">
          {environment ? (
            <MobilePageSwitcher />
          ) : (
            <span className="truncate text-sm font-medium">
              {breadcrumbs[breadcrumbs.length - 1]?.title}
            </span>
          )}
        </div>
      </div>
      {onOpenCommandPalette && (
        <Button
          type="button"
          variant="outline"
          size="sm"
          className="text-muted-foreground h-8 gap-1.5"
          onClick={onOpenCommandPalette}
        >
          <Search className="size-3.5" />
          <span className="hidden sm:inline">Search</span>
          <kbd className="bg-muted hidden rounded px-1 py-0.5 font-mono text-[10px] sm:inline">
            ⌘K
          </kbd>
        </Button>
      )}
    </header>
  )
}
