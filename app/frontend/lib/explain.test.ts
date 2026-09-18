import { describe, expect, it } from "vitest"

import { explainWarnings } from "@/lib/explain"

describe("explainWarnings", () => {
  it("returns nothing for an empty plan", () => {
    expect(explainWarnings("")).toEqual([])
  })

  it("flags a SQLite full table scan", () => {
    const warnings = explainWarnings("SCAN comments")
    expect(warnings).toHaveLength(1)
    expect(warnings[0].message).toContain("every row")
  })

  it("does not flag a SQLite search that uses an index", () => {
    expect(
      explainWarnings("SEARCH comments USING INDEX index_comments_on_post_id"),
    ).toEqual([])
  })

  it("does not flag a scan that is served by a covering index", () => {
    expect(
      explainWarnings("SCAN comments USING COVERING INDEX index_comments"),
    ).toEqual([])
  })

  it("flags a Postgres sequential scan", () => {
    expect(
      explainWarnings("Seq Scan on comments  (cost=0.00..35.50 rows=8)")[0],
    ).toMatchObject({ line: 1 })
  })

  it("flags a SQLite temporary b-tree sort", () => {
    expect(explainWarnings("USE TEMP B-TREE FOR ORDER BY")).toEqual([])
    expect(explainWarnings("USING TEMP B-TREE FOR ORDER BY")).toHaveLength(1)
  })

  it("flags a MySQL filesort", () => {
    expect(
      explainWarnings("Extra: Using where; Using filesort")[0].message,
    ).toContain("Filesort")
  })

  it("flags a MySQL full-scan join type", () => {
    expect(
      explainWarnings("table: comments  type: ALL  rows: 4210"),
    ).toHaveLength(1)
  })

  it("reports 1-based line numbers and skips clean lines", () => {
    const plan = [
      "QUERY PLAN",
      "SEARCH posts USING INTEGER PRIMARY KEY (rowid=?)",
      "SCAN comments",
    ].join("\n")
    const warnings = explainWarnings(plan)
    expect(warnings.map((w) => w.line)).toEqual([3])
    expect(warnings[0].message).toContain("every row")
  })

  it("reports one warning per matching rule on the same line", () => {
    const warnings = explainWarnings("type: ALL  Extra: Using filesort")
    expect(warnings.map((w) => w.line)).toEqual([1, 1])
  })
})
