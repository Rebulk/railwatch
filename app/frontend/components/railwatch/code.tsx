import { cn } from "@/lib/utils"

export function Sql({
  children,
  className,
}: {
  children: string
  className?: string
}) {
  return (
    <code
      className={cn("block max-w-full truncate font-mono text-xs", className)}
      title={children}
    >
      {children}
    </code>
  )
}

export function Mono({
  children,
  className,
}: {
  children: React.ReactNode
  className?: string
}) {
  return <span className={cn("font-mono text-xs", className)}>{children}</span>
}
