import { Head, Link, usePage } from "@inertiajs/react"
import { Menu } from "lucide-react"
import { useState } from "react"

import { MarketingFooter } from "@/components/marketing/footer"
import { MarketingNav } from "@/components/marketing/nav"
import { Button } from "@/components/ui/button"
import { cn } from "@/lib/utils"
import type { SharedProps } from "@/types"

interface NavDoc {
  id: string
  title: string
  href: string
}
interface Props {
  doc: { id: string; title: string; html: string }
  nav: { section: string; title: string; docs: NavDoc[] }[]
}

// Railwatch's manual, rendered server-side from the Markdown the gem ships.
// Public, so it sits inside the marketing chrome rather than the app shell.
export default function DocShow(p: Props) {
  const { auth } = usePage<SharedProps>().props
  const [open, setOpen] = useState(false)
  const sidebar = (
    <nav className="space-y-6 text-sm">
      {p.nav.map((group) => (
        <div key={group.section}>
          <div className="label-caps mb-2">{group.title}</div>
          <ul className="space-y-0.5">
            {group.docs.map((d) => (
              <li key={d.id}>
                <Link
                  href={d.href}
                  onClick={() => setOpen(false)}
                  className={cn(
                    "hover:bg-accent block rounded-md px-2 py-1",
                    d.id === p.doc.id
                      ? "bg-accent font-medium"
                      : "text-muted-foreground",
                  )}
                >
                  {d.title}
                </Link>
              </li>
            ))}
          </ul>
        </div>
      ))}
    </nav>
  )
  return (
    <>
      <Head title={`${p.doc.title} · Docs`} />
      <MarketingNav signedIn={Boolean(auth?.user)} />
      <div className="mx-auto flex w-full max-w-6xl gap-10 px-6 pb-16">
        <aside className="hidden w-56 shrink-0 md:block">
          <div className="sticky top-6">{sidebar}</div>
        </aside>
        <div className="min-w-0 flex-1">
          <div className="mb-4 md:hidden">
            <Button
              variant="outline"
              size="sm"
              onClick={() => setOpen((v) => !v)}
            >
              <Menu className="size-4" />
              {open ? "Hide contents" : "Contents"}
            </Button>
            {open && (
              <div className="bg-card mt-3 rounded-lg border p-4">
                {sidebar}
              </div>
            )}
          </div>
          <article
            className="prose prose-neutral dark:prose-invert prose-headings:scroll-mt-6 prose-headings:font-semibold prose-headings:tracking-tight prose-h1:text-3xl prose-a:text-primary prose-code:rounded prose-code:bg-muted prose-code:px-1 prose-code:py-0.5 prose-code:font-mono prose-code:text-[0.85em] prose-code:font-normal prose-code:before:content-none prose-code:after:content-none prose-pre:bg-muted prose-pre:text-foreground prose-pre:border prose-table:text-sm prose-th:label-caps max-w-none"
            dangerouslySetInnerHTML={{ __html: p.doc.html }}
          />
        </div>
      </div>
      <MarketingFooter />
    </>
  )
}
