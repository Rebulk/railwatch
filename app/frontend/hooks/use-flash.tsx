import { usePage } from "@inertiajs/react"
import { useEffect } from "react"

import { signalToast } from "@/components/railwatch/signal-toast"
import type { FlashData } from "@/types"

// Rails flash to signal aspects: alert is stop, warning is caution, notice
// is clear.
function showFlash(flash: FlashData) {
  if (flash.alert) signalToast("stop", flash.alert)
  if (flash.warning) signalToast("caution", flash.warning)
  if (flash.notice) signalToast("clear", flash.notice)
}

export function useFlash() {
  const { flash } = usePage()

  useEffect(() => {
    // setTimeout + cleanup prevents double-firing in React StrictMode
    const timeout = setTimeout(() => showFlash(flash), 0)
    return () => clearTimeout(timeout)
  }, [flash])
}
