import { act, fireEvent, render, screen } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"

import { SavedViewsMenu } from "@/components/railwatch/saved-views"
import {
  applicationEnvironmentSavedViewPath,
  applicationEnvironmentSavedViewsPath,
} from "@/routes"
import type { EnvironmentContext, SavedView } from "@/types"

const post = vi.fn()
const patch = vi.fn()
const destroy = vi.fn()
const visit = vi.fn()
let pageProps: Record<string, unknown> = {}
let pageUrl = ""

vi.mock("@inertiajs/react", () => ({
  router: {
    visit: (...args: unknown[]) => {
      visit(...args)
    },
    post: (...args: unknown[]) => {
      post(...args)
    },
    patch: (...args: unknown[]) => {
      patch(...args)
    },
    delete: (...args: unknown[]) => {
      destroy(...args)
    },
  },
  usePage: () => ({ props: pageProps, url: pageUrl }),
}))

const environment: EnvironmentContext = {
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
}

const view = (attributes: Partial<SavedView> = {}): SavedView => ({
  id: 5,
  name: "Acme logs",
  page: "logs",
  query: "tenant:acme",
  window: "24h",
  params: {},
  pinned: true,
  shared: true,
  mine: true,
  url: "/apps/1/envs/10/logs?window=24h&q=tenant%3Aacme",
  ...attributes,
})

beforeEach(() => {
  post.mockClear()
  patch.mockClear()
  destroy.mockClear()
  visit.mockClear()
  pageUrl = "/apps/1/envs/10/logs?window=7d&q=level%3Aerror&sort=when"
  pageProps = { environment, window: "7d", saved_views: [view()] }
})

// Radix opens its menu on a primary-button pointerdown, which fireEvent
// cannot build (jsdom has no PointerEvent) and which userEvent's pointer
// emulation takes tens of seconds to deliver against this tree. A plain
// MouseEvent named "pointerdown" is what the trigger's handler reads.
const openMenu = () =>
  act(() => {
    screen
      .getByText("Views")
      .dispatchEvent(
        new MouseEvent("pointerdown", { bubbles: true, button: 0 }),
      )
  })

describe("SavedViewsMenu list", () => {
  it("lists the views saved on this page", () => {
    render(<SavedViewsMenu page="logs" />)

    openMenu()

    expect(screen.getByText("Acme logs")).toBeInTheDocument()
  })

  it("leaves out views belonging to another page", () => {
    pageProps = {
      environment,
      saved_views: [view({ page: "requests", name: "5xx checkout" })],
    }
    render(<SavedViewsMenu page="logs" />)

    openMenu()

    expect(screen.queryByText("5xx checkout")).not.toBeInTheDocument()
    expect(screen.getByText("No saved views yet")).toBeInTheDocument()
  })

  it("visits the view's server-built url when it is picked", () => {
    render(<SavedViewsMenu page="logs" />)

    openMenu()
    fireEvent.click(screen.getByText("Acme logs"))

    expect(visit).toHaveBeenCalledWith(view().url)
  })

  it("unpins one of my views without navigating to it", () => {
    render(<SavedViewsMenu page="logs" />)

    openMenu()
    fireEvent.click(screen.getByLabelText("Unpin Acme logs"))

    expect(patch).toHaveBeenCalledWith(
      applicationEnvironmentSavedViewPath(1, 10, 5),
      { pinned: false },
      { preserveScroll: true },
    )
    expect(visit).not.toHaveBeenCalled()
  })

  it("deletes one of my views", () => {
    render(<SavedViewsMenu page="logs" />)

    openMenu()
    fireEvent.click(screen.getByLabelText("Delete Acme logs"))

    expect(destroy).toHaveBeenCalledWith(
      applicationEnvironmentSavedViewPath(1, 10, 5),
      { preserveScroll: true },
    )
  })

  it("offers no pin or delete action on someone else's view", () => {
    pageProps = { environment, saved_views: [view({ mine: false })] }
    render(<SavedViewsMenu page="logs" />)

    openMenu()

    expect(screen.queryByLabelText("Delete Acme logs")).not.toBeInTheDocument()
  })
})

describe("SavedViewsMenu save dialog", () => {
  it("posts the name plus the window, query, and extra params in the current url", () => {
    render(<SavedViewsMenu page="logs" />)

    openMenu()
    fireEvent.click(screen.getByText("Save current view…"))
    fireEvent.change(screen.getByLabelText("Name"), {
      target: { value: "Errors this week" },
    })
    fireEvent.click(screen.getByText("Save view"))

    expect(post).toHaveBeenCalledWith(
      applicationEnvironmentSavedViewsPath(1, 10),
      {
        name: "Errors this week",
        page: "logs",
        query: "level:error",
        window: "7d",
        pinned: true,
        shared: true,
        params: { sort: "when" },
      },
      { preserveScroll: true },
    )
  })

  it("will not save a view without a name", () => {
    render(<SavedViewsMenu page="logs" />)

    openMenu()
    fireEvent.click(screen.getByText("Save current view…"))

    expect(screen.getByText("Save view")).toBeDisabled()
  })
})
