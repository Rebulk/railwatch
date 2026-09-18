import { useTicker } from "@/hooks/use-ticker"
import { ago, when } from "@/lib/format"

export function RelativeTime({
  iso,
  className,
}: {
  iso: string | null | undefined
  className?: string
}) {
  useTicker()
  if (!iso) return <span className={className}>never</span>
  return (
    <span className={className} title={when(iso)}>
      {ago(iso)}
    </span>
  )
}
