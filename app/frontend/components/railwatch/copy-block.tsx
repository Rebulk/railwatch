import { CheckIcon, CopyIcon } from "lucide-react"
import { useState } from "react"

import { Button } from "@/components/ui/button"
import { useClipboard } from "@/hooks/use-clipboard"
import { cn } from "@/lib/utils"

const COPIED_RESET_MS = 1500

// A code block with a copy button in its corner. Everything Railwatch asks a
// developer to paste somewhere else — a Gemfile line, a token, an MCP client
// config — goes through this, so "copy" behaves the same everywhere.
export function CopyBlock({
  code,
  className,
}: {
  code: string
  className?: string
}) {
  const [, copy] = useClipboard()
  const [justCopied, setJustCopied] = useState(false)

  const handleCopy = () => {
    void copy(code).then((ok) => {
      if (!ok) return
      setJustCopied(true)
      window.setTimeout(() => setJustCopied(false), COPIED_RESET_MS)
    })
  }

  return (
    <div className={cn("relative", className)}>
      <pre className="bg-muted overflow-x-auto rounded p-3 pr-10 font-mono text-xs">
        {code}
      </pre>
      <Button
        type="button"
        aria-label={justCopied ? "Copied code" : "Copy code"}
        variant="ghost"
        size="icon"
        className="absolute top-1.5 right-1.5 size-6"
        onClick={handleCopy}
      >
        {justCopied ? (
          <CheckIcon className="size-3.5 text-emerald-500" />
        ) : (
          <CopyIcon className="size-3.5 opacity-60" />
        )}
      </Button>
    </div>
  )
}
