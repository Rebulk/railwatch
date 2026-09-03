// Lantern browser client for Inertia. Reports each visit's duration,
// component, and prop payload size to /lantern/beacon so the platform can
// show real page-load timing. Batches and sends with sendBeacon on
// pagehide, or every 5s.
import { router } from "@inertiajs/react"

type Visit = {
  started_at: number
  url: string
  method: string
  component?: string
  duration_ms?: number
  status?: "success" | "error" | "cancelled"
  partial?: boolean
  only?: string[]
  props_bytes?: number
}

const queue: Visit[] = []
let current: Visit | null = null
let timer: number | undefined

function endpoint() {
  return "/lantern/beacon"
}

function csrf() {
  return document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""
}

function flush() {
  if (queue.length === 0) return
  const body = JSON.stringify({ visits: queue.splice(0, queue.length) })
  const blob = new Blob([body], { type: "application/json" })
  if (navigator.sendBeacon?.(endpoint(), blob)) return
  fetch(endpoint(), {
    method: "POST",
    body,
    headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf() },
    keepalive: true,
  }).catch(() => {})
}

export function startLantern() {
  router.on("start", (event) => {
    const v = event.detail.visit
    current = {
      started_at: Date.now(),
      url: v.url.toString(),
      method: v.method,
      partial: Boolean(v.only?.length || v.except?.length),
      only: v.only,
    }
  })
  router.on("success", (event) => {
    if (!current) return
    current.component = event.detail.page.component
    current.props_bytes = JSON.stringify(event.detail.page.props ?? {}).length
    current.status = "success"
  })
  router.on("error", () => {
    if (current) current.status = "error"
  })
  router.on("finish", () => {
    if (!current) return
    current.duration_ms = Date.now() - current.started_at
    current.status ??= "cancelled"
    queue.push(current)
    current = null
    if (queue.length >= 20) flush()
  })
  timer ??= window.setInterval(flush, 5000)
  window.addEventListener("pagehide", flush)
}
