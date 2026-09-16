import { CheckIcon, CopyIcon } from "lucide-react"
import { useState } from "react"

import { Button } from "@/components/ui/button"
import { useClipboard } from "@/hooks/use-clipboard"
import { cn } from "@/lib/utils"

const COPIED_RESET_MS = 1500

export function CopyId({
  value,
  label,
  className,
}: {
  value: string
  label?: string
  className?: string
}) {
  const [, copy] = useClipboard()
  const [justCopied, setJustCopied] = useState(false)

  const handleCopy = () => {
    void copy(value).then((ok) => {
      if (!ok) return
      setJustCopied(true)
      window.setTimeout(() => setJustCopied(false), COPIED_RESET_MS)
    })
  }

  return (
    <Button
      type="button"
      variant="ghost"
      size="sm"
      className={cn(
        "h-auto gap-1.5 px-1.5 py-0.5 font-mono text-xs",
        className,
      )}
      onClick={handleCopy}
    >
      {label ?? value}
      {justCopied ? (
        <CheckIcon className="size-3 text-emerald-500" />
      ) : (
        <CopyIcon className="size-3 opacity-60" />
      )}
    </Button>
  )
}
