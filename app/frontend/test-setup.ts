import "@testing-library/jest-dom/vitest"

import { cleanup } from "@testing-library/react"
import { afterEach } from "vitest"

afterEach(() => {
  cleanup()
})

// cmdk's CommandList measures itself with a ResizeObserver, which jsdom
// doesn't implement.
class ResizeObserverStub {
  observe = () => undefined
  unobserve = () => undefined
  disconnect = () => undefined
}
window.ResizeObserver ??= ResizeObserverStub

// jsdom has no browser top layer. nwsapi 2.2.27 recursively calls its own
// matches implementation for these selectors, hanging Floating UI's
// isTopLayer check. Model the unsupported states without mocking Popover
// or its interactions, and keep normal selector matching intact.
// Saved method is explicitly called with its original receiver below.
// eslint-disable-next-line @typescript-eslint/unbound-method
const matches = Element.prototype.matches
Element.prototype.matches = function (selector: string) {
  if (selector === ":modal" || selector === ":fullscreen") return false
  return matches.call(this, selector)
}

// cmdk scrolls the selected item into view; jsdom doesn't implement layout.
if (!window.HTMLElement.prototype.scrollIntoView) {
  window.HTMLElement.prototype.scrollIntoView = () => undefined
}
