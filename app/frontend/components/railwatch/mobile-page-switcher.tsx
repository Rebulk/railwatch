import { router, usePage } from "@inertiajs/react"
import { Bookmark, ChevronDown } from "lucide-react"

import { isViewActive, samePage } from "@/components/railwatch/saved-views"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { ENV_PAGE_GROUPS, envPages } from "@/lib/env-pages"
import { cn } from "@/lib/utils"
import type { SharedProps } from "@/types"

// Phone-only replacement for the sidebar's environment navigation: the
// current page's name in the header opens a menu of every environment page.
export function MobilePageSwitcher() {
  const page = usePage<SharedProps>()
  const { environment } = page.props
  if (!environment) return null
  const items = envPages(
    environment.application_id,
    environment.id,
    page.props.window as string,
  )
  const current = page.url.split("?")[0]
  const pinnedViews = (page.props.saved_views ?? []).filter((v) => v.pinned)
  // Overview's path is a prefix of every other page's, so prefer the
  // longest matching path rather than the first.
  const active =
    items
      .filter((i) => {
        const path = i.href.split("?")[0]
        return current === path || current.startsWith(path + "/")
      })
      .sort((a, b) => b.href.length - a.href.length)[0] ?? items[0]
  return (
    <DropdownMenu>
      <DropdownMenuTrigger className="flex min-w-0 items-center gap-1 text-sm font-medium">
        {active.icon && <active.icon className="size-4 shrink-0 opacity-70" />}
        <span className="truncate">{active.title}</span>
        <ChevronDown className="size-3.5 shrink-0 opacity-60" />
      </DropdownMenuTrigger>
      <DropdownMenuContent
        align="start"
        className="max-h-[70vh] w-60 overflow-y-auto"
      >
        {ENV_PAGE_GROUPS.map((group, gi) => (
          <div key={group.key}>
            {gi > 0 && <DropdownMenuSeparator />}
            <DropdownMenuLabel className="label-caps">
              {group.title}
            </DropdownMenuLabel>
            {items
              .filter((i) => i.group === group.key)
              .map((item) => (
                <div key={item.title}>
                  <DropdownMenuItem
                    onSelect={() => router.visit(item.href)}
                    className={item === active ? "bg-accent" : undefined}
                  >
                    {item.icon && <item.icon className="size-4" />}
                    {item.title}
                  </DropdownMenuItem>
                  {pinnedViews
                    .filter((view) => samePage(view.url, item.href))
                    .map((view) => (
                      <DropdownMenuItem
                        key={view.id}
                        onSelect={() => router.visit(view.url)}
                        className={cn(
                          "pl-8 text-xs",
                          isViewActive(page.url, view.url) && "bg-accent",
                        )}
                      >
                        <Bookmark className="size-3.5 opacity-60" />
                        {view.name}
                      </DropdownMenuItem>
                    ))}
                </div>
              ))}
          </div>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
