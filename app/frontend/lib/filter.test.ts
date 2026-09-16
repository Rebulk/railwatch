import { describe, expect, it } from "vitest"

import { parseFilter, serializeFilter } from "@/lib/filter"

describe("parseFilter", () => {
  it("extracts key:value tokens into fields", () => {
    expect(parseFilter("status:500 method:GET").fields).toEqual({
      status: "500",
      method: "GET",
    })
  })

  it("collects non-token words into text, in order", () => {
    expect(parseFilter("hello world").text).toBe("hello world")
  })

  it("mixes field tokens and free text, keeping free text order but not position", () => {
    const parsed = parseFilter("status:500 broken thing method:GET")
    expect(parsed.fields).toEqual({ status: "500", method: "GET" })
    expect(parsed.text).toBe("broken thing")
  })

  it("treats a word with an uppercase key as text, since keys must be lowercase", () => {
    // TOKEN regex requires [a-z_]+ before the colon.
    expect(parseFilter("Status:500").fields).toEqual({})
    expect(parseFilter("Status:500").text).toBe("Status:500")
  })

  it("keeps quote characters as part of the value, since TOKEN does not strip quotes", () => {
    // The regex is `\S+` for the value half, so a quoted value with no
    // internal space is captured quotes-and-all.
    expect(parseFilter('key:"quoted"').fields).toEqual({ key: '"quoted"' })
  })

  it("splits a quoted value containing a space into two tokens on whitespace", () => {
    const parsed = parseFilter('key:"two words"')
    expect(parsed.fields).toEqual({ key: '"two' })
    expect(parsed.text).toBe('words"')
  })

  it("treats a colon with no value as text", () => {
    expect(parseFilter("status:").fields).toEqual({})
    expect(parseFilter("status:").text).toBe("status:")
  })

  it("returns empty text and fields for an empty string", () => {
    expect(parseFilter("")).toEqual({ text: "", fields: {} })
  })

  it("returns empty text and fields for a whitespace-only string", () => {
    expect(parseFilter("   ")).toEqual({ text: "", fields: {} })
  })

  it("collapses repeated whitespace between words", () => {
    expect(parseFilter("status:500    method:GET").fields).toEqual({
      status: "500",
      method: "GET",
    })
  })
})

describe("serializeFilter", () => {
  it("joins field tokens as key:value", () => {
    expect(
      serializeFilter({ text: "", fields: { status: "500", method: "GET" } }),
    ).toBe("status:500 method:GET")
  })

  it("appends free text after field tokens", () => {
    expect(
      serializeFilter({ text: "broken thing", fields: { status: "500" } }),
    ).toBe("status:500 broken thing")
  })

  it("omits the text segment entirely when text is empty", () => {
    expect(serializeFilter({ text: "", fields: { status: "500" } })).toBe(
      "status:500",
    )
  })

  it("returns an empty string for an empty parsed filter", () => {
    expect(serializeFilter({ text: "", fields: {} })).toBe("")
  })
})

describe("parseFilter/serializeFilter round trip", () => {
  it("round trips key:value tokens with free text", () => {
    const query = "status:500 method:GET some free text"
    expect(serializeFilter(parseFilter(query))).toBe(
      "status:500 method:GET some free text",
    )
  })

  it("round trips a field-only query", () => {
    const query = "status:500"
    expect(serializeFilter(parseFilter(query))).toBe(query)
  })

  it("round trips free text alone", () => {
    const query = "just some text"
    expect(serializeFilter(parseFilter(query))).toBe(query)
  })

  it("round trips the empty string", () => {
    expect(serializeFilter(parseFilter(""))).toBe("")
  })
})
