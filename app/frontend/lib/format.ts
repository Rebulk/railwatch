export function ms(value: number | null | undefined, digits = 1): string {
  if (value === null || value === undefined) return "–"
  if (value >= 1000) return `${(value / 1000).toFixed(2)}s`
  if (value < 1 && value > 0) return `${(value * 1000).toFixed(0)}µs`
  return `${value.toFixed(digits)}ms`
}

export function count(value: number | null | undefined): string {
  if (value === null || value === undefined) return "–"
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(1)}M`
  if (value >= 10_000) return `${(value / 1000).toFixed(1)}k`
  return value.toLocaleString()
}

export function bytes(value: number | null | undefined): string {
  if (!value) return "–"
  if (value >= 1 << 30) return `${(value / (1 << 30)).toFixed(1)} GB`
  if (value >= 1 << 20) return `${(value / (1 << 20)).toFixed(1)} MB`
  if (value >= 1 << 10) return `${(value / (1 << 10)).toFixed(1)} KB`
  return `${value} B`
}

// A single cheap model call costs a fraction of a cent, so the precision
// has to follow the magnitude: $0.0043 is the useful reading, $0.00 is not.
// null means unpriced, which is not the same as free -- callers that can
// say so in words should, rather than relying on the dash.
export function usd(value: number | null | undefined): string {
  if (value === null || value === undefined) return "–"
  if (value === 0) return "$0"
  if (value < 0.01) return `$${value.toFixed(4)}`
  if (value < 1000) return `$${value.toFixed(2)}`
  return `$${Math.round(value).toLocaleString()}`
}

export function pct(numerator: number, denominator: number): string {
  if (!denominator) return "0%"
  return `${((numerator / denominator) * 100).toFixed(1)}%`
}

export function ago(iso: string | null | undefined): string {
  if (!iso) return "never"
  const diff = (Date.now() - new Date(iso).getTime()) / 1000
  if (diff < 60) return `${Math.max(0, Math.floor(diff))}s ago`
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`
  return `${Math.floor(diff / 86400)}d ago`
}

export function when(iso: string | null | undefined): string {
  if (!iso) return "–"
  return new Date(iso).toLocaleString(undefined, {
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  })
}

export function statusTone(
  status: number | null | undefined,
  outcome?: string | null,
) {
  if (outcome === "failed") return "destructive"
  if (outcome === "processed") return "success"
  if (!status) return "muted"
  if (status >= 500) return "destructive"
  if (status >= 400) return "warning"
  if (status >= 300) return "muted"
  return "success"
}
