import { act, renderHook } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

import { useIsLive, useLive } from "@/hooks/use-live"

interface Callbacks {
  connected?: () => void
  disconnected?: () => void
  received?: (data: unknown) => void
}

let created: { id: number; callbacks: Callbacks }[]
const unsubscribe = vi.fn()
const reload = vi.fn()

// vi.mock calls are hoisted above the imports above, so mocking these two
// modules here (rather than statically importing them) is enough to swap
// out the real WebSocket consumer and Inertia's router for the hook.
vi.mock("@/lib/cable", () => ({
  getConsumer: () => ({
    subscriptions: {
      create: (params: { id: number }, callbacks: Callbacks) => {
        created.push({ id: params.id, callbacks })
        return { unsubscribe }
      },
    },
  }),
}))

vi.mock("@inertiajs/react", () => ({
  router: {
    reload: (options: { onSuccess?: () => void; onFinish?: () => void }) => {
      reload(options)
      options.onSuccess?.()
      options.onFinish?.()
    },
  },
}))

function setVisibility(state: DocumentVisibilityState) {
  Object.defineProperty(document, "visibilityState", {
    value: state,
    configurable: true,
  })
  document.dispatchEvent(new Event("visibilitychange"))
}

function fire(data: unknown) {
  created[0].callbacks.received?.(data)
}

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(new Date("2026-09-03T12:00:00.000Z"))
  created = []
  unsubscribe.mockClear()
  reload.mockClear()
  localStorage.clear()
  setVisibility("visible")
})

afterEach(() => {
  vi.useRealTimers()
})

describe("useLive", () => {
  it("reloads on the first event and throttles a second event inside 5s", () => {
    renderHook(() => useLive(1, { only: ["a"] }))
    act(() => fire({}))
    expect(reload).toHaveBeenCalledTimes(1)
    act(() => fire({}))
    expect(reload).toHaveBeenCalledTimes(1)
  })

  it("reloads again once 5s have passed", () => {
    renderHook(() => useLive(1, { only: ["a"] }))
    act(() => fire({}))
    vi.advanceTimersByTime(5_000)
    act(() => fire({}))
    expect(reload).toHaveBeenCalledTimes(2)
  })

  it("skips reloading while hidden, then reloads once on return", () => {
    renderHook(() => useLive(1, { only: ["a"] }))
    setVisibility("hidden")
    act(() => fire({}))
    expect(reload).not.toHaveBeenCalled()
    act(() => setVisibility("visible"))
    expect(reload).toHaveBeenCalledTimes(1)
  })

  it("never reloads while paused", () => {
    const { result } = renderHook(() => useLive(1, { only: ["a"] }))
    act(() => result.current.setPaused(true))
    act(() => fire({}))
    expect(reload).not.toHaveBeenCalled()
  })

  it("unsubscribes on unmount", () => {
    const { unmount } = renderHook(() => useLive(1, { only: ["a"] }))
    unmount()
    expect(unsubscribe).toHaveBeenCalledTimes(1)
  })

  it("coalesces a burst into one trailing refresh", () => {
    renderHook(() => useLive(1))
    act(() => fire({}))
    act(() => {
      fire({})
      fire({})
      vi.advanceTimersByTime(4_999)
    })
    expect(reload).toHaveBeenCalledTimes(1)
    act(() => {
      vi.advanceTimersByTime(1)
    })
    expect(reload).toHaveBeenCalledTimes(2)
  })

  it("keeps pending updates through pause and visibility changes", () => {
    const { result } = renderHook(() => useLive(1))
    act(() => {
      fire({})
      fire({})
    })
    act(() => result.current.setPaused(true))
    act(() => {
      setVisibility("hidden")
      vi.advanceTimersByTime(5_000)
    })
    act(() => result.current.setPaused(false))
    expect(reload).toHaveBeenCalledTimes(1)
    act(() => setVisibility("visible"))
    expect(reload).toHaveBeenCalledTimes(2)
    expect(result.current.lastRefreshedAt).toBe(Date.now())
  })

  it("cancels old environment timers and ignores old callbacks", () => {
    const { rerender, unmount, result } = renderHook(({ id }) => useLive(id), {
      initialProps: { id: 1 },
    })
    act(() => {
      fire({})
      fire({})
    })
    rerender({ id: 2 })
    expect(result.current.lastRefreshedAt).toBeNull()
    act(() => {
      fire({})
      vi.advanceTimersByTime(5_000)
    })
    expect(reload).toHaveBeenCalledTimes(1)
    act(() => {
      created[1].callbacks.received?.({})
      created[1].callbacks.received?.({})
    })
    unmount()
    act(() => {
      vi.advanceTimersByTime(5_000)
    })
    expect(reload).toHaveBeenCalledTimes(2)
  })
})

// What a rolling number on the page reads to decide whether it may animate.
describe("useIsLive", () => {
  function connect() {
    created[0].callbacks.connected?.()
  }

  it("is false until the subscription connects", () => {
    const { result } = renderHook(() => useIsLive())
    renderHook(() => useLive(1))
    expect(result.current).toBe(false)
    act(connect)
    expect(result.current).toBe(true)
  })

  it("is false while live updates are paused", () => {
    const { result } = renderHook(() => useIsLive())
    const live = renderHook(() => useLive(1))
    act(connect)
    act(() => live.result.current.setPaused(true))
    expect(result.current).toBe(false)
    act(() => live.result.current.setPaused(false))
    expect(result.current).toBe(true)
  })

  it("is false once the page with the subscription has gone", () => {
    const { result } = renderHook(() => useIsLive())
    const live = renderHook(() => useLive(1))
    act(connect)
    expect(result.current).toBe(true)
    act(() => live.unmount())
    expect(result.current).toBe(false)
  })
})
