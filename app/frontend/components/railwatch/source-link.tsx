import { usePage } from "@inertiajs/react"
import { ExternalLink } from "lucide-react"

import { sourceUrl } from "@/lib/source-link"
import { cn } from "@/lib/utils"
import type { SharedProps } from "@/types"

// A "file:line" location, linked to the line on the code host (pinned to the
// deploy that produced it) or opened in the viewer's editor, depending on
// their profile. Renders plain text when we can't build a URL.
export function SourceLink({
  location,
  deploy,
  className,
}: {
  location: string
  // The deploy the location came from, used as the git ref so the link points
  // at the code that was actually running. (Named `deploy`, not `ref`: React
  // treats a `ref` prop as an element ref.)
  deploy?: string | null
  className?: string
}) {
  const { auth, environment } = usePage<SharedProps>().props
  const match = /^(.*):(\d+)$/.exec(location)
  const url = match
    ? sourceUrl({
        file: match[1],
        line: Number(match[2]),
        repositoryUrl: environment?.repository_url,
        ref: deploy,
        defaultBranch: environment?.default_branch,
        editor: auth.user.editor,
        editorRoot: auth.user.editor_root,
      })
    : null

  if (!url)
    return (
      <span className={cn("truncate font-mono text-xs", className)}>
        {location}
      </span>
    )
  const external = url.startsWith("http")
  return (
    <a
      href={url}
      {...(external ? { target: "_blank", rel: "noreferrer" } : {})}
      className={cn(
        "inline-flex min-w-0 items-center gap-1 font-mono text-xs hover:underline",
        className,
      )}
    >
      <span className="truncate">{location}</span>
      <ExternalLink className="size-3 shrink-0 opacity-60" />
    </a>
  )
}
