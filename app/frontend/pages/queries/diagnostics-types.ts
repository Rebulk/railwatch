export interface QueryRecommendation {
  id: string
  kind: "index" | "scan" | "sort" | "spill" | "n_plus_one"
  basis: "sql" | "plan" | "capture"
  title: string
  explanation: string
  action: string
  table?: string
  columns?: string[]
  code?: string | null
  evidence: {
    source: "sql" | "plan" | "n_plus_one" | "source"
    text: string
    line?: number
    truncated?: boolean
  }[]
}

export interface QueryDiagnostics {
  status: "analyzed" | "unsupported" | "unavailable" | "limited"
  adapter: string
  connection: string
  source: string
  limitations: string[]
  recommendations: QueryRecommendation[]
}
