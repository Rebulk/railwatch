import { cn } from "@/lib/utils"

const KEYWORDS = new Set([
  "SELECT",
  "FROM",
  "WHERE",
  "JOIN",
  "LEFT",
  "INNER",
  "ON",
  "AND",
  "OR",
  "ORDER",
  "BY",
  "GROUP",
  "LIMIT",
  "OFFSET",
  "INSERT",
  "INTO",
  "VALUES",
  "UPDATE",
  "SET",
  "DELETE",
  "RETURNING",
  "AS",
  "IN",
  "IS",
  "NULL",
  "NOT",
  "DISTINCT",
  "COUNT",
  "SUM",
  "AVG",
  "MAX",
  "MIN",
  "CASE",
  "WHEN",
  "THEN",
  "ELSE",
  "END",
])

type TokenKind =
  "identifier" | "string" | "placeholder" | "number" | "keyword" | "text"

interface Token {
  text: string
  kind: TokenKind
}

// Quoted identifier | string literal | `?` bind placeholder | number | bare word.
// Anything not matched (whitespace, punctuation) falls through as plain text.
const TOKEN_RE =
  /("(?:[^"]|"")*"|`(?:[^`]|``)*`)|('(?:[^']|'')*')|(\?)|(\b\d+(?:\.\d+)?\b)|(\b[A-Za-z_][A-Za-z_0-9]*\b)/g

function tokenize(sql: string): Token[] {
  const tokens: Token[] = []
  let last = 0
  TOKEN_RE.lastIndex = 0
  let m: RegExpExecArray | null
  while ((m = TOKEN_RE.exec(sql))) {
    if (m.index > last)
      tokens.push({ text: sql.slice(last, m.index), kind: "text" })
    const [full, ident, str, placeholder, number] = m
    if (ident) tokens.push({ text: full, kind: "identifier" })
    else if (str) tokens.push({ text: full, kind: "string" })
    else if (placeholder) tokens.push({ text: full, kind: "placeholder" })
    else if (number) tokens.push({ text: full, kind: "number" })
    else if (KEYWORDS.has(full.toUpperCase()))
      tokens.push({ text: full, kind: "keyword" })
    else tokens.push({ text: full, kind: "text" })
    last = TOKEN_RE.lastIndex
  }
  if (last < sql.length) tokens.push({ text: sql.slice(last), kind: "text" })
  return tokens
}

const toneClass: Record<TokenKind, string> = {
  keyword: "text-primary font-semibold",
  string: "text-emerald-600 dark:text-emerald-400",
  number: "text-amber-600 dark:text-amber-400",
  placeholder: "text-primary font-semibold",
  identifier: "text-muted-foreground",
  text: "",
}

export function SqlBlock({
  sql,
  wrap = false,
  inline = false,
  className,
}: {
  sql: string
  wrap?: boolean
  inline?: boolean
  className?: string
}) {
  const tokens = tokenize(sql)
  const Tag = inline ? "span" : "code"
  return (
    <Tag
      className={cn(
        "font-mono text-xs",
        wrap ? "break-words whitespace-pre-wrap" : "block max-w-full truncate",
        className,
      )}
      title={wrap ? undefined : sql}
    >
      {tokens.map((t, i) => (
        <span key={i} className={toneClass[t.kind] || undefined}>
          {t.text}
        </span>
      ))}
    </Tag>
  )
}
