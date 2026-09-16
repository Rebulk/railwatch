import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { beforeEach, describe, expect, it, vi } from "vitest"

import { CommandPalette } from "@/components/railwatch/command-palette"
import { applicationEnvironmentOverviewPath, dashboardPath } from "@/routes"
import type { ApplicationSummary, EnvironmentContext } from "@/types"

const visit = vi.fn()
let pageProps: Record<string, unknown> = {}

vi.mock("@inertiajs/react", () => ({
  router: {
    visit: (...args: unknown[]) => {
      visit(...args)
    },
  },
  usePage: () => ({ props: pageProps }),
}))

const applications: ApplicationSummary[] = [
  {
    id: 1,
    name: "Storefront",
    slug: "storefront",
    issue_prefix: "STORE",
    environments: [
      {
        id: 10,
        name: "Production",
        slug: "production",
        last_seen_at: null,
        paused: false,
      },
    ],
  },
]

beforeEach(() => {
  visit.mockClear()
  pageProps = { applications, environment: undefined, window: undefined }
})

describe("CommandPalette static navigation", () => {
  it("lists the fixed navigation items", () => {
    render(<CommandPalette open={true} onOpenChange={vi.fn()} />)
    expect(screen.getByText("Dashboard")).toBeInTheDocument()
    expect(screen.getByText("Issues")).toBeInTheDocument()
    expect(screen.getByText("Integrations")).toBeInTheDocument()
    expect(screen.getByText("Members")).toBeInTheDocument()
  })

  it("visits the real dashboardPath and closes the palette when Dashboard is selected", async () => {
    const onOpenChange = vi.fn()
    const user = userEvent.setup()
    render(<CommandPalette open={true} onOpenChange={onOpenChange} />)

    await user.click(screen.getByText("Dashboard"))

    expect(visit).toHaveBeenCalledWith(dashboardPath())
    expect(onOpenChange).toHaveBeenCalledWith(false)
  })
})

describe("CommandPalette applications group", () => {
  it('lists each application\'s environments as "App · Env"', () => {
    render(<CommandPalette open={true} onOpenChange={vi.fn()} />)
    expect(screen.getByText("Storefront · Production")).toBeInTheDocument()
  })

  it("visits the real applicationEnvironmentOverviewPath when an app/env is selected", async () => {
    const user = userEvent.setup()
    render(<CommandPalette open={true} onOpenChange={vi.fn()} />)

    await user.click(screen.getByText("Storefront · Production"))

    expect(visit).toHaveBeenCalledWith(
      applicationEnvironmentOverviewPath(1, 10),
    )
  })
})

describe("CommandPalette environment-scoped group", () => {
  it("is absent when no environment is active in shared props", () => {
    render(<CommandPalette open={true} onOpenChange={vi.fn()} />)
    expect(screen.queryByText("Requests")).not.toBeInTheDocument()
  })

  it('lists environment sub-pages, headed by "App · Env", when an environment is active', () => {
    pageProps = {
      applications,
      environment: {
        id: 10,
        name: "Production",
        slug: "production",
        application_id: 1,
        application_name: "Storefront",
        issue_prefix: "STORE",
        last_seen_at: null,
        paused: false,
        token_prefix: "abc123def456",
        repository_url: null,
        default_branch: "main",
      } satisfies EnvironmentContext,
      window: "24h",
    }
    render(<CommandPalette open={true} onOpenChange={vi.fn()} />)

    expect(screen.getByText("Overview")).toBeInTheDocument()
    expect(screen.getByText("Requests")).toBeInTheDocument()
  })
})

describe("CommandPalette search group", () => {
  it('has no "Search issues for" item while the query is empty', () => {
    render(<CommandPalette open={true} onOpenChange={vi.fn()} />)
    expect(screen.queryByText(/Search issues for/)).not.toBeInTheDocument()
  })

  it('adds a "Search issues for" item once text is typed', async () => {
    const user = userEvent.setup()
    render(<CommandPalette open={true} onOpenChange={vi.fn()} />)

    await user.type(
      screen.getByPlaceholderText("Search pages, applications, issues…"),
      "timeout",
    )

    expect(
      screen.getByText((text) => text.includes("Search issues for")),
    ).toBeInTheDocument()
  })
})
