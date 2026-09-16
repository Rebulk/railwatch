import { act, renderHook } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

import { useRowNav } from "@/hooks/use-row-nav"

interface Row {
  id: number
}

const rows: Row[] = [{ id: 1 }, { id: 2 }, { id: 3 }]

function fireKey(key: string, target: EventTarget = document.body) {
  const event = new KeyboardEvent("keydown", { key, bubbles: true })
  Object.defineProperty(event, "target", { value: target })
  document.dispatchEvent(event)
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe("useRowNav", () => {
  it("moves the highlight down with j and up with k", () => {
    const { result } = renderHook(() =>
      useRowNav({ rows, rowKey: (r) => r.id, onOpen: () => undefined }),
    )
    expect(result.current.highlighted).toBeNull()

    act(() => fireKey("j"))
    expect(result.current.highlighted).toBe(1)

    act(() => fireKey("j"))
    expect(result.current.highlighted).toBe(2)

    act(() => fireKey("k"))
    expect(result.current.highlighted).toBe(1)
  })

  it("does not move past the first or last row", () => {
    const { result } = renderHook(() =>
      useRowNav({ rows, rowKey: (r) => r.id, onOpen: () => undefined }),
    )
    act(() => fireKey("k"))
    expect(result.current.highlighted).toBe(1)

    act(() => fireKey("j"))
    act(() => fireKey("j"))
    act(() => fireKey("j"))
    expect(result.current.highlighted).toBe(3)
  })

  it("opens the highlighted row on Enter", () => {
    const onOpen = vi.fn()
    renderHook(() => useRowNav({ rows, rowKey: (r) => r.id, onOpen }))
    act(() => fireKey("j"))
    act(() => fireKey("Enter"))
    expect(onOpen).toHaveBeenCalledExactlyOnceWith(rows[0])
  })

  it("opens the highlighted row in a new tab on o", () => {
    const onOpen = vi.fn()
    renderHook(() => useRowNav({ rows, rowKey: (r) => r.id, onOpen }))
    act(() => fireKey("j"))
    act(() => fireKey("o"))
    expect(onOpen).toHaveBeenCalledExactlyOnceWith(rows[0], { newTab: true })
  })

  it("clears the highlight on Escape", () => {
    const { result } = renderHook(() =>
      useRowNav({ rows, rowKey: (r) => r.id, onOpen: () => undefined }),
    )
    act(() => fireKey("j"))
    expect(result.current.highlighted).toBe(1)
    act(() => fireKey("Escape"))
    expect(result.current.highlighted).toBeNull()
  })

  it("ignores keydowns while focus is in a text input", () => {
    const input = document.createElement("input")
    document.body.append(input)
    const { result } = renderHook(() =>
      useRowNav({ rows, rowKey: (r) => r.id, onOpen: () => undefined }),
    )
    act(() => fireKey("j", input))
    expect(result.current.highlighted).toBeNull()
    input.remove()
  })

  it("does nothing when disabled", () => {
    const { result } = renderHook(() =>
      useRowNav({
        rows,
        rowKey: (r) => r.id,
        onOpen: () => undefined,
        enabled: false,
      }),
    )
    act(() => fireKey("j"))
    expect(result.current.highlighted).toBeNull()
  })

  it("routes shortcuts only to the active table", () => {
    const first = renderHook(() =>
      useRowNav({ rows, rowKey: (r) => r.id, onOpen: vi.fn() }),
    )
    const second = renderHook(() =>
      useRowNav({ rows, rowKey: (r) => r.id, onOpen: vi.fn() }),
    )
    act(() => fireKey("j"))
    expect(first.result.current.highlighted).toBe(1)
    expect(second.result.current.highlighted).toBeNull()
    act(() => second.result.current.activate())
    act(() => fireKey("j"))
    expect(first.result.current.highlighted).toBeNull()
    expect(second.result.current.highlighted).toBe(1)
  })

  it("yields to controls, composition and browser shortcuts", () => {
    const { result } = renderHook(() =>
      useRowNav({ rows, rowKey: (r) => r.id, onOpen: vi.fn() }),
    )
    const button = document.createElement("button")
    act(() => fireKey("j", button))
    for (const options of [
      { ctrlKey: true },
      { metaKey: true },
      { isComposing: true },
    ]) {
      act(() => {
        document.dispatchEvent(
          new KeyboardEvent("keydown", { key: "j", ...options }),
        )
      })
    }
    const handled = new KeyboardEvent("keydown", { key: "j", cancelable: true })
    handled.preventDefault()
    act(() => {
      document.dispatchEvent(handled)
    })
    expect(result.current.highlighted).toBeNull()
  })
})
