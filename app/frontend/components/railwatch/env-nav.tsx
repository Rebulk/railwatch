import { Link, usePage } from "@inertiajs/react"
import { Bookmark, ChevronRight } from "lucide-react"
import { useState } from "react"

import { isViewActive, samePage } from "@/components/railwatch/saved-views"
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from "@/components/ui/collapsible"
import {
  SidebarGroup,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarMenuSub,
  SidebarMenuSubButton,
  SidebarMenuSubItem,
} from "@/components/ui/sidebar"
import { ENV_PAGE_GROUPS, envPages } from "@/lib/env-pages"
import { cn } from "@/lib/utils"
import type { SharedProps } from "@/types"

// Environment navigation in the sidebar: Overview at the top, then one
// collapsible section per page group (Activity, Monitoring, Settings). The
// section containing the current page starts open; the others start
// closed so the list stays short.
export function EnvNav() {
  const page = usePage<SharedProps>()
  const { environment } = page.props
  const current = page.url.split("?")[0]
  const [openOverride, setOpenOverride] = useState<
    Record<string, boolean | undefined>
  >({})
  if (!environment) return null

  const items = envPages(
    environment.application_id,
    environment.id,
    page.props.window as string,
  )
  const pinnedViews = (page.props.saved_views ?? []).filter((v) => v.pinned)
  const isCurrent = (href: string) => {
    const path = href.split("?")[0]
    return current === path || current.startsWith(path + "/")
  }
  const overview = items[0]

  return (
    <SidebarGroup className="p-0">
      <SidebarMenu>
        <SidebarMenuItem>
          <SidebarMenuButton
            asChild
            isActive={current === overview.href.split("?")[0]}
            tooltip={{ children: overview.title }}
          >
            <Link href={overview.href} prefetch>
              {overview.icon && <overview.icon />}
              <span>{overview.title}</span>
            </Link>
          </SidebarMenuButton>
        </SidebarMenuItem>
        {ENV_PAGE_GROUPS.map((group) => {
          const groupItems = items.filter(
            (i) => i.group === group.key && i !== overview,
          )
          const containsCurrent = groupItems.some((i) => isCurrent(i.href))
          const open = openOverride[group.key] ?? containsCurrent
          const GroupIcon = groupItems[0]?.icon
          return (
            <Collapsible
              key={group.key}
              open={open}
              onOpenChange={(v) =>
                setOpenOverride((o) => ({ ...o, [group.key]: v }))
              }
              className="group/collapsible"
            >
              <SidebarMenuItem>
                <CollapsibleTrigger asChild>
                  <SidebarMenuButton
                    tooltip={{ children: group.title }}
                    className={cn(containsCurrent && "text-sidebar-foreground")}
                  >
                    {GroupIcon && <GroupIcon />}
                    <span>{group.title}</span>
                    <ChevronRight className="ml-auto size-3.5 opacity-60 transition-transform group-data-[state=open]/collapsible:rotate-90" />
                  </SidebarMenuButton>
                </CollapsibleTrigger>
                <CollapsibleContent>
                  <SidebarMenuSub className="mr-0 gap-0.5 pr-0">
                    {groupItems.map((item) => (
                      <SidebarMenuSubItem key={item.title}>
                        <SidebarMenuSubButton
                          asChild
                          isActive={isCurrent(item.href)}
                        >
                          <Link href={item.href} prefetch>
                            <span>{item.title}</span>
                          </Link>
                        </SidebarMenuSubButton>
                        {pinnedViews
                          .filter((view) => samePage(view.url, item.href))
                          .map((view) => (
                            <SidebarMenuSubButton
                              key={view.id}
                              asChild
                              size="sm"
                              className="pl-4"
                              isActive={isViewActive(page.url, view.url)}
                            >
                              <Link href={view.url}>
                                <Bookmark className="opacity-60" />
                                <span>{view.name}</span>
                              </Link>
                            </SidebarMenuSubButton>
                          ))}
                      </SidebarMenuSubItem>
                    ))}
                  </SidebarMenuSub>
                </CollapsibleContent>
              </SidebarMenuItem>
            </Collapsible>
          )
        })}
      </SidebarMenu>
    </SidebarGroup>
  )
}
