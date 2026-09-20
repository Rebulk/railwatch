import { useSyncExternalStore } from "react"

const QUERY = "(prefers-reduced-motion: reduce)"

// Whether the user has asked their OS for less motion. Read in JavaScript
// rather than left to CSS: a global `animation: none` does not stop a Web
// Animations API animation, so a component that animates has to decide not
// to. Follows the media query live, so turning the setting on stops the
// motion without a reload.
function subscribe(onChange: () => void) {
  const query = window.matchMedia(QUERY)
  query.addEventListener("change", onChange)
  return () => {
    query.removeEventListener("change", onChange)
  }
}

function snapshot() {
  return window.matchMedia(QUERY).matches
}

export function useReducedMotion() {
  // Server-rendered markup carries no motion, so it renders as if reduced.
  return useSyncExternalStore(subscribe, snapshot, () => true)
}
