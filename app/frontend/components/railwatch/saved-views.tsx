import { router, usePage } from "@inertiajs/react"
import {
  Bookmark,
  BookmarkPlus,
  Check,
  ChevronDown,
  Link2,
  Pin,
  PinOff,
  Trash2,
} from "lucide-react"
import { useState } from "react"

import { Button } from "@/components/ui/button"
import { Checkbox } from "@/components/ui/checkbox"
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { cn } from "@/lib/utils"
import * as R from "@/routes"
import type { SavedView, SharedProps } from "@/types"

// A view's URL and the browser's differ only in the order of their query
// params, so both are normalised (empty values dropped, keys sorted) before
// comparing. Used by the menu and by both navigations to mark the view the
// page is currently showing.
function normalize(url: string) {
  const [path, search] = url.split("?")
  const params = [...new URLSearchParams(search)]
    .filter(([, value]) => value !== "")
    .sort(([a], [b]) => a.localeCompare(b))
  return `${path}?${new URLSearchParams(params).toString()}`
}

export function isViewActive(currentUrl: string, viewUrl: string) {
  return normalize(currentUrl) === normalize(viewUrl)
}

export function samePage(viewUrl: string, pageHref: string) {
  return viewUrl.split("?")[0] === pageHref.split("?")[0]
}

// Saved views for one page, as a PageHeader action: a menu of everyone's
// visible views, a dialog that saves the filters currently in the URL, and
// a copy-link button for sharing the exact page you are looking at.
export function SavedViewsMenu({ page }: { page: string }) {
  const inertia = usePage<SharedProps>()
  const { environment, saved_views: allViews = [] } = inertia.props
  const [saving, setSaving] = useState(false)
  const [name, setName] = useState("")
  const [pinned, setPinned] = useState(true)
  const [shared, setShared] = useState(true)
  const [copied, setCopied] = useState(false)
  const a = environment!.application_id
  const e = environment!.id
  const views = allViews.filter((v) => v.page === page)
  const search = new URLSearchParams(inertia.url.split("?")[1] ?? "")

  const viewPath = (v: SavedView) =>
    R.applicationEnvironmentSavedViewPath(a, e, v.id)

  const save = () => {
    const params: Record<string, string> = {}
    for (const [key, value] of search) {
      if (key !== "window" && key !== "q" && value) params[key] = value
    }
    router.post(
      R.applicationEnvironmentSavedViewsPath(a, e),
      {
        name: name.trim(),
        page,
        query: search.get("q") ?? "",
        window: search.get("window") ?? inertia.props.window ?? "",
        pinned,
        shared,
        params,
      },
      { preserveScroll: true },
    )
    setSaving(false)
    setName("")
  }

  const copyLink = () => {
    void navigator.clipboard?.writeText(globalThis.location.href)
    setCopied(true)
    globalThis.setTimeout(() => setCopied(false), 1500)
  }

  return (
    <>
      <div className="flex shrink-0 items-center gap-1">
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="outline" size="sm" className="h-8 gap-1.5 px-2">
              <Bookmark className="size-3.5" />
              <span className="label-caps text-foreground">Views</span>
              <ChevronDown className="size-3 opacity-60" />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="w-64">
            <DropdownMenuLabel className="label-caps">
              Saved views
            </DropdownMenuLabel>
            {views.length === 0 && (
              <DropdownMenuItem disabled>No saved views yet</DropdownMenuItem>
            )}
            {views.map((v) => (
              <DropdownMenuItem
                key={v.id}
                onSelect={() => router.visit(v.url)}
                className={cn(isViewActive(inertia.url, v.url) && "bg-accent")}
              >
                <span className="truncate">{v.name}</span>
                {v.mine && (
                  <span className="ml-auto flex shrink-0 items-center gap-0.5">
                    <button
                      type="button"
                      aria-label={`${v.pinned ? "Unpin" : "Pin"} ${v.name}`}
                      className="text-muted-foreground hover:text-foreground p-0.5"
                      onClick={(event) => {
                        event.preventDefault()
                        event.stopPropagation()
                        router.patch(
                          viewPath(v),
                          { pinned: !v.pinned },
                          { preserveScroll: true },
                        )
                      }}
                    >
                      {v.pinned ? (
                        <PinOff className="size-3.5" />
                      ) : (
                        <Pin className="size-3.5" />
                      )}
                    </button>
                    <button
                      type="button"
                      aria-label={`Delete ${v.name}`}
                      className="text-muted-foreground hover:text-destructive p-0.5"
                      onClick={(event) => {
                        event.preventDefault()
                        event.stopPropagation()
                        router.delete(viewPath(v), { preserveScroll: true })
                      }}
                    >
                      <Trash2 className="size-3.5" />
                    </button>
                  </span>
                )}
              </DropdownMenuItem>
            ))}
            <DropdownMenuSeparator />
            <DropdownMenuItem onSelect={() => setSaving(true)}>
              <BookmarkPlus className="size-3.5" />
              Save current view…
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
        <Button
          variant="outline"
          size="sm"
          className="h-8 px-2"
          aria-label="Copy link to this view"
          onClick={copyLink}
        >
          {copied ? (
            <Check className="size-3.5" />
          ) : (
            <Link2 className="size-3.5" />
          )}
        </Button>
      </div>
      <Dialog open={saving} onOpenChange={setSaving}>
        <DialogContent className="sm:max-w-sm">
          <DialogHeader>
            <DialogTitle>Save this view</DialogTitle>
            <DialogDescription>
              Keeps the filters, window, and sort currently in the URL under a
              name you can link to.
            </DialogDescription>
          </DialogHeader>
          <div className="flex flex-col gap-3">
            <div className="grid gap-1.5">
              <Label htmlFor="saved-view-name">Name</Label>
              <Input
                id="saved-view-name"
                value={name}
                onChange={(event) => setName(event.target.value)}
                placeholder="5xx checkout requests"
              />
            </div>
            <Label className="gap-2 font-normal">
              <Checkbox
                checked={pinned}
                onCheckedChange={(value) => setPinned(value === true)}
              />
              Pin to the sidebar
            </Label>
            <Label className="gap-2 font-normal">
              <Checkbox
                checked={shared}
                onCheckedChange={(value) => setShared(value === true)}
              />
              Share with the team
            </Label>
          </div>
          <DialogFooter>
            <Button size="sm" onClick={save} disabled={!name.trim()}>
              Save view
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  )
}
