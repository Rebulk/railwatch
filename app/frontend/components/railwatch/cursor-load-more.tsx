import { router } from "@inertiajs/react"
import { useState } from "react"

import { Button } from "@/components/ui/button"
import type { CursorMeta } from "@/types"

export function CursorLoadMore({
  meta,
  href,
  only,
}: {
  meta: CursorMeta
  href: (cursor: string) => string
  only: string[]
}) {
  const [loading, setLoading] = useState(false)
  if (!meta.has_more || !meta.next_cursor) return null

  return (
    <div className="flex justify-center pt-3">
      <Button
        type="button"
        variant="outline"
        disabled={loading}
        onClick={() =>
          router.visit(href(meta.next_cursor!), {
            only,
            preserveState: true,
            preserveScroll: true,
            onStart: () => setLoading(true),
            onFinish: () => setLoading(false),
          })
        }
      >
        {loading ? "Loading…" : "Load " + meta.limit + " more"}
      </Button>
    </div>
  )
}
