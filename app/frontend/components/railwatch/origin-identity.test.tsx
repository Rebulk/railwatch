import { router } from "@inertiajs/react"
import { fireEvent, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

import { DataTable } from "@/components/railwatch/data-table"
import { OriginIdentity } from "@/components/railwatch/origin-identity"

const scope = {
  applicationId: 7,
  environmentId: 9,
  window: "24h",
} as const

afterEach(() => vi.restoreAllMocks())

describe("OriginIdentity", () => {
  it("links a user only when the environment supplied a matching Person", () => {
    const { rerender } = render(
      <OriginIdentity
        {...scope}
        kind="user"
        user_ref="acme.co:42"
        tenant="acme"
        person={{ ref: "acme.co:42", name: "Ada" }}
      />,
    )

    expect(screen.getByRole("link", { name: "Ada" })).toHaveAttribute(
      "href",
      "/apps/7/envs/9/users/acme%2Eco:42?window=24h",
    )

    rerender(
      <OriginIdentity
        {...scope}
        kind="user"
        user_ref="historical:7"
        tenant={null}
        person={null}
      />,
    )
    expect(screen.queryByRole("link")).not.toBeInTheDocument()
    expect(screen.getByText("historical:7")).toBeInTheDocument()
  })

  it("links a propagated tenant and preserves dots in the route segment", () => {
    render(
      <OriginIdentity
        {...scope}
        kind="tenant"
        user_ref={null}
        tenant="acme.co"
        person={null}
      />,
    )

    expect(screen.getByRole("link", { name: "acme.co" })).toHaveAttribute(
      "href",
      "/apps/7/envs/9/tenants/acme%2Eco?window=24h",
    )
  })

  it("renders absent historical metadata without a link", () => {
    render(
      <OriginIdentity
        {...scope}
        kind="user"
        user_ref={null}
        tenant={null}
        person={null}
      />,
    )

    expect(screen.getByText("–")).toBeInTheDocument()
    expect(screen.queryByRole("link")).not.toBeInTheDocument()
  })

  it("keeps user and tenant links from activating their clickable row", () => {
    const onRowClick = vi.fn()
    const visit = vi.spyOn(router, "visit").mockImplementation(() => undefined)
    const row = {
      id: 1,
      user_ref: "acme.co:42",
      tenant: "acme.co",
      person: { ref: "acme.co:42", name: "Ada" },
    }
    render(
      <DataTable
        rows={[row]}
        rowKey={(item) => item.id}
        onRowClick={onRowClick}
        columns={[
          {
            key: "user",
            header: "User",
            cell: (item) => <OriginIdentity {...scope} {...item} kind="user" />,
          },
          {
            key: "tenant",
            header: "Tenant",
            cell: (item) => (
              <OriginIdentity {...scope} {...item} kind="tenant" />
            ),
          },
        ]}
      />,
    )

    fireEvent.click(screen.getByRole("link", { name: "Ada" }))
    fireEvent.click(screen.getByRole("link", { name: "acme.co" }))

    expect(visit).toHaveBeenCalledTimes(2)
    expect(onRowClick).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole("link", { name: "Ada" }).closest("tr")!)
    expect(onRowClick).toHaveBeenCalledExactlyOnceWith(row)
  })

  it("preserves canonical custom bounds in both identity links", () => {
    const range = {
      from: "2026-09-01T01:02:03.123456Z",
      to: "2026-09-02T04:05:06.654321Z",
    }
    render(
      <>
        <OriginIdentity
          {...scope}
          window="custom"
          range={range}
          kind="user"
          user_ref="acme.co:42"
          tenant="acme.co"
          person={{ ref: "acme.co:42", name: "Ada" }}
        />
        <OriginIdentity
          {...scope}
          window="custom"
          range={range}
          kind="tenant"
          user_ref="acme.co:42"
          tenant="acme.co"
          person={{ ref: "acme.co:42", name: "Ada" }}
        />
      </>,
    )

    for (const link of screen.getAllByRole("link")) {
      const url = new URL(link.getAttribute("href")!, "https://example.test")
      expect(url.searchParams.get("from")).toBe(range.from)
      expect(url.searchParams.get("to")).toBe(range.to)
      expect(url.searchParams.has("window")).toBe(false)
    }
  })

  it("preserves a fixed window in both identity links", () => {
    render(
      <>
        <OriginIdentity
          {...scope}
          window="7d"
          kind="user"
          user_ref="acme.co:42"
          tenant="acme.co"
          person={{ ref: "acme.co:42", name: "Ada" }}
        />
        <OriginIdentity
          {...scope}
          window="7d"
          kind="tenant"
          user_ref="acme.co:42"
          tenant="acme.co"
          person={{ ref: "acme.co:42", name: "Ada" }}
        />
      </>,
    )

    for (const link of screen.getAllByRole("link")) {
      const url = new URL(link.getAttribute("href")!, "https://example.test")
      expect(url.searchParams.get("window")).toBe("7d")
      expect(url.searchParams.has("from")).toBe(false)
      expect(url.searchParams.has("to")).toBe(false)
    }
  })
})
