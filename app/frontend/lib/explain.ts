export interface ExplainWarning {
  // 1-based line number within the plan text.
  line: number
  message: string
}

// The parts of a captured query plan that mean the database is doing more
// work than an index would let it. Each rule carries the plain-English
// reason, so the panel can say what's wrong rather than just colouring a
// line. Covers SQLite (EXPLAIN QUERY PLAN), Postgres and MySQL.
const RULES: { test: RegExp; skip?: RegExp; message: string }[] = [
  {
    test: /\bSCAN\b/i,
    skip: /\bUSING\s+(?:COVERING\s+)?INDEX\b/i,
    message: "Reads every row of the table — no index covers this filter.",
  },
  {
    test: /\bSeq Scan\b/i,
    message:
      "Sequential scan — Postgres reads the whole table; an index on the filtered column avoids it.",
  },
  {
    test: /\bUSING TEMP B-TREE\b/i,
    message:
      "Builds a temporary B-tree to sort — an index matching the ORDER BY removes it.",
  },
  {
    test: /filesort/i,
    message:
      "Filesort — MySQL sorts the rows itself; an index matching the ORDER BY removes it.",
  },
  {
    test: /\btype:\s*ALL\b/i,
    message:
      "Join type ALL — MySQL has no usable index and scans the whole table.",
  },
]

// Risky lines of `plan`, in order. One line can raise more than one warning
// (a full scan that also sorts), so callers should collect by line number
// rather than assume a single hit.
export function explainWarnings(plan: string): ExplainWarning[] {
  return plan
    .split("\n")
    .flatMap((text, index) =>
      RULES.filter((r) => r.test.test(text) && !r.skip?.test(text)).map(
        (r) => ({ line: index + 1, message: r.message }),
      ),
    )
}
