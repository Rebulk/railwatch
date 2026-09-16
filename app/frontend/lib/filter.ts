// Mirrors app/models/filters.rb: "key:value key2:value2 free text" tokens.
const TOKEN = /^([a-z_]+):(\S+)$/

export interface ParsedFilter {
  text: string
  fields: Record<string, string>
}

export function parseFilter(query: string): ParsedFilter {
  const text: string[] = []
  const fields: Record<string, string> = {}
  for (const word of query.trim().split(/\s+/)) {
    if (!word) continue
    const m = TOKEN.exec(word)
    if (m) fields[m[1]] = m[2]
    else text.push(word)
  }
  return { text: text.join(" "), fields }
}

export function serializeFilter(parsed: ParsedFilter): string {
  const tokens = Object.entries(parsed.fields).map(([k, v]) => `${k}:${v}`)
  if (parsed.text) tokens.push(parsed.text)
  return tokens.join(" ")
}
