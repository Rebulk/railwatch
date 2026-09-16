import { Check, ChevronDown, ChevronRight, Copy } from "lucide-react"
import { useState } from "react"

import { Button } from "@/components/ui/button"
import { useClipboard } from "@/hooks/use-clipboard"
import { cn } from "@/lib/utils"

type Json = null | boolean | number | string | Json[] | { [key: string]: Json }

function isContainer(v: unknown): v is Json[] | Record<string, Json> {
  return v !== null && typeof v === "object"
}

function primitiveClass(v: Json) {
  if (v === null) return "text-muted-foreground"
  if (typeof v === "string") return "text-emerald-600 dark:text-emerald-400"
  if (typeof v === "number") return "text-amber-600 dark:text-amber-400"
  if (typeof v === "boolean") return "text-primary"
  return ""
}

function Primitive({ value }: { value: string | number | boolean | null }) {
  const text =
    value === null
      ? "null"
      : typeof value === "string"
        ? `"${value}"`
        : String(value)
  return <span className={primitiveClass(value)}>{text}</span>
}

function Node({
  label,
  value,
  depth,
  collapsed,
}: {
  label?: string
  value: Json
  depth: number
  collapsed: boolean
}) {
  const [open, setOpen] = useState(!collapsed)
  const indent = { paddingLeft: `${depth * 12}px` }

  if (!isContainer(value)) {
    return (
      <div style={indent}>
        {label !== undefined && (
          <span className="text-muted-foreground">{label}: </span>
        )}
        <Primitive value={value} />
      </div>
    )
  }

  const entries = Array.isArray(value)
    ? value.map((v, i) => [String(i), v] as const)
    : Object.entries(value)
  const [open_, close_] = Array.isArray(value) ? ["[", "]"] : ["{", "}"]

  if (entries.length === 0) {
    return (
      <div style={indent}>
        {label !== undefined && (
          <span className="text-muted-foreground">{label}: </span>
        )}
        <span className="text-muted-foreground">
          {open_}
          {close_}
        </span>
      </div>
    )
  }

  return (
    <div>
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className="hover:bg-muted/60 inline-flex items-center gap-0.5 rounded"
        style={indent}
      >
        {open ? (
          <ChevronDown className="text-muted-foreground size-3" />
        ) : (
          <ChevronRight className="text-muted-foreground size-3" />
        )}
        {label !== undefined && (
          <span className="text-muted-foreground">{label}:</span>
        )}
        <span className="text-muted-foreground">
          {open_}
          {!open && `…${entries.length}…${close_}`}
        </span>
      </button>
      {open && (
        <div>
          {entries.map(([k, v]) => (
            <Node
              key={k}
              label={Array.isArray(value) ? undefined : k}
              value={v}
              depth={depth + 1}
              collapsed={collapsed}
            />
          ))}
          <div className="text-muted-foreground" style={indent}>
            {close_}
          </div>
        </div>
      )}
    </div>
  )
}

export function JsonViewer({
  data,
  collapsed = false,
  className,
}: {
  data: unknown
  collapsed?: boolean
  className?: string
}) {
  const [, copy] = useClipboard()
  const [copied, setCopied] = useState(false)
  return (
    <div
      className={cn(
        "bg-muted/60 relative rounded p-2 pr-8 font-mono text-xs",
        className,
      )}
    >
      <Button
        type="button"
        variant="ghost"
        size="icon-sm"
        className="absolute top-1 right-1"
        onClick={() => {
          void (async () => {
            const ok = await copy(JSON.stringify(data, null, 2))
            if (ok) {
              setCopied(true)
              setTimeout(() => setCopied(false), 1200)
            }
          })()
        }}
      >
        {copied ? (
          <Check className="size-3.5" />
        ) : (
          <Copy className="size-3.5" />
        )}
      </Button>
      <Node value={data as Json} depth={0} collapsed={collapsed} />
    </div>
  )
}
