import { router } from "@inertiajs/react"
import { useEffect, useRef, useState, useSyncExternalStore } from "react"

import { getConsumer } from "@/lib/cable"

const RELOAD_THROTTLE_MS = 5_000
const PAUSED_STORAGE_KEY = "railwatch:live-paused"

export interface LiveEvent {
  event: string
  at: string
  counts: Record<string, number>
}

// Whether live updates are actually flowing right now: subscribed and not
// paused. The page's LiveToggle owns the one `useLive` subscription, so
// anything else that needs the answer -- a number that only animates while
// the data behind it is moving -- reads it from here rather than opening a
// second WebSocket subscription of its own.
let live = false
const liveWatchers = new Set<() => void>()

function publishLive(value: boolean) {
  if (live === value) return
  live = value
  for (const watcher of liveWatchers) watcher()
}

function subscribeLive(onChange: () => void) {
  liveWatchers.add(onChange)
  return () => {
    liveWatchers.delete(onChange)
  }
}

export function useIsLive() {
  return useSyncExternalStore(
    subscribeLive,
    () => live,
    () => false,
  )
}

// Subscribes to an environment's EnvironmentChannel stream. On each message,
// reloads the page's Inertia data props in the background (a partial
// `router.reload`, not a navigation), throttled to at most once every 5s and
// only while the tab is visible; one reload fires on return to the tab if an
// event arrived while it was hidden. Pass `only` to limit the reload to
// specific props, matching whatever `router.reload({ only })` accepts;
// omit it to refresh every prop the current page was rendered with.
export function useLive(
  environmentId: number,
  {
    only,
    onEvent,
  }: { only?: string[]; onEvent?: (event: LiveEvent) => void } = {},
) {
  const [connected, setConnected] = useState(false)
  const [lastEventAt, setLastEventAt] = useState<number | null>(null)
  const [lastRefreshedAt, setLastRefreshedAt] = useState<number | null>(null)
  const [subscribedEnvironment, setSubscribedEnvironment] =
    useState(environmentId)
  if (subscribedEnvironment !== environmentId) {
    setSubscribedEnvironment(environmentId)
    setConnected(false)
    setLastEventAt(null)
    setLastRefreshedAt(null)
  }
  const [paused, setPausedState] = useState(() => {
    if (typeof window === "undefined") return false
    return localStorage.getItem(PAUSED_STORAGE_KEY) === "1"
  })

  const onlyRef = useRef(only)
  const onEventRef = useRef(onEvent)
  const pausedRef = useRef(paused)
  useEffect(() => {
    onlyRef.current = only
    onEventRef.current = onEvent
    pausedRef.current = paused
  })

  const scheduleRef = useRef<() => void>(() => undefined)

  useEffect(() => {
    publishLive(connected && !paused)
    return () => publishLive(false)
  }, [connected, paused])

  function setPaused(value: boolean) {
    pausedRef.current = value
    localStorage.setItem(PAUSED_STORAGE_KEY, value ? "1" : "0")
    setPausedState(value)
    scheduleRef.current()
  }

  useEffect(() => {
    let disposed = false
    let pending = false
    let inFlight = false
    let lastReloadAt = -Infinity
    let timer: ReturnType<typeof setTimeout> | undefined
    let cancelReload: (() => void) | undefined

    function reload() {
      pending = false
      inFlight = true
      lastReloadAt = Date.now()
      // router.reload always preserves scroll and state; that's why
      // ReloadOptions omits those keys (unlike router.visit).
      router.reload({
        only: onlyRef.current,
        onCancelToken: (token) => {
          cancelReload = () => token.cancel()
        },
        onSuccess: () => {
          if (!disposed) setLastRefreshedAt(Date.now())
        },
        onFinish: () => {
          cancelReload = undefined
          inFlight = false
          maybeReload()
        },
      })
    }

    function maybeReload() {
      clearTimeout(timer)
      timer = undefined
      if (
        disposed ||
        !pending ||
        inFlight ||
        pausedRef.current ||
        document.visibilityState !== "visible"
      )
        return
      const delay = RELOAD_THROTTLE_MS - (Date.now() - lastReloadAt)
      if (delay > 0) timer = setTimeout(maybeReload, delay)
      else reload()
    }

    function onVisibilityChange() {
      maybeReload()
    }

    document.addEventListener("visibilitychange", onVisibilityChange)
    scheduleRef.current = maybeReload
    const subscription = getConsumer().subscriptions.create(
      { channel: "EnvironmentChannel", id: environmentId },
      {
        connected: () => {
          if (!disposed) setConnected(true)
        },
        disconnected: () => {
          if (!disposed) setConnected(false)
        },
        received: (data: LiveEvent) => {
          if (disposed) return
          setLastEventAt(Date.now())
          onEventRef.current?.(data)
          pending = true
          maybeReload()
        },
      },
    )

    return () => {
      disposed = true
      cancelReload?.()
      clearTimeout(timer)
      scheduleRef.current = () => undefined
      document.removeEventListener("visibilitychange", onVisibilityChange)
      subscription.unsubscribe()
    }
  }, [environmentId])

  return { connected, lastEventAt, lastRefreshedAt, paused, setPaused }
}
