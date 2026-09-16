import { describe, expect, it } from "vitest"

import { commitUrl, compareUrl, sourceUrl } from "@/lib/source-link"

const repo = "https://github.com/acme/widgets"
const frame = { file: "app/models/user.rb", line: 12 }

describe("sourceUrl", () => {
  it("pins a GitHub blob link to the deploy's ref", () => {
    expect(
      sourceUrl({
        ...frame,
        repositoryUrl: repo,
        ref: "abc1234",
        defaultBranch: "main",
        editor: "github",
      }),
    ).toBe(
      "https://github.com/acme/widgets/blob/abc1234/app/models/user.rb#L12",
    )
  })

  it("falls back to the default branch when the deploy has no ref", () => {
    expect(
      sourceUrl({
        ...frame,
        repositoryUrl: repo,
        defaultBranch: "trunk",
        editor: "github",
      }),
    ).toBe("https://github.com/acme/widgets/blob/trunk/app/models/user.rb#L12")
  })

  it("uses GitLab's /-/blob/ path", () => {
    expect(
      sourceUrl({
        ...frame,
        repositoryUrl: "https://gitlab.com/acme/widgets",
        ref: "abc1234",
        editor: "gitlab",
      }),
    ).toBe(
      "https://gitlab.com/acme/widgets/-/blob/abc1234/app/models/user.rb#L12",
    )
  })

  it("strips a trailing .git and slashes from the repository URL", () => {
    expect(
      sourceUrl({
        ...frame,
        repositoryUrl: "https://github.com/acme/widgets.git/",
        ref: "abc1234",
        editor: "github",
      }),
    ).toBe(
      "https://github.com/acme/widgets/blob/abc1234/app/models/user.rb#L12",
    )
  })

  it("returns null for a code host with no repository URL configured", () => {
    expect(
      sourceUrl({ ...frame, defaultBranch: "main", editor: "github" }),
    ).toBeNull()
  })

  it("returns null for a code host with neither a ref nor a default branch", () => {
    expect(sourceUrl({ ...frame, repositoryUrl: repo, editor: "github" })).toBe(
      null,
    )
  })

  it("builds a vscode link from the local checkout path", () => {
    expect(
      sourceUrl({ ...frame, editor: "vscode", editorRoot: "/home/cole/app" }),
    ).toBe("vscode://file/home/cole/app/app/models/user.rb:12")
  })

  it("builds a cursor link", () => {
    expect(
      sourceUrl({ ...frame, editor: "cursor", editorRoot: "/home/cole/app" }),
    ).toBe("cursor://file/home/cole/app/app/models/user.rb:12")
  })

  it("builds a zed link", () => {
    expect(
      sourceUrl({ ...frame, editor: "zed", editorRoot: "/home/cole/app" }),
    ).toBe("zed://file/home/cole/app/app/models/user.rb:12")
  })

  it("builds a rubymine navigate link", () => {
    expect(
      sourceUrl({ ...frame, editor: "rubymine", editorRoot: "/home/cole/app" }),
    ).toBe(
      "jetbrains://rubymine/navigate/reference?project=&path=%2Fhome%2Fcole%2Fapp%2Fapp%2Fmodels%2Fuser.rb%3A12",
    )
  })

  it("builds a textmate link with the line as a query param", () => {
    expect(
      sourceUrl({ ...frame, editor: "textmate", editorRoot: "/home/cole/app" }),
    ).toBe(
      "txmt://open?url=file%3A%2F%2F%2Fhome%2Fcole%2Fapp%2Fapp%2Fmodels%2Fuser.rb&line=12",
    )
  })

  it("ignores a trailing slash on the local checkout path", () => {
    expect(
      sourceUrl({ ...frame, editor: "vscode", editorRoot: "/home/cole/app/" }),
    ).toBe("vscode://file/home/cole/app/app/models/user.rb:12")
  })

  it("returns null for an editor scheme with no local checkout path", () => {
    expect(sourceUrl({ ...frame, editor: "vscode" })).toBeNull()
  })

  it("returns null for an unknown editor", () => {
    expect(
      sourceUrl({ ...frame, editor: "emacs", editorRoot: "/home/cole/app" }),
    ).toBeNull()
  })

  it("returns null without a file", () => {
    expect(
      sourceUrl({
        file: "",
        line: 12,
        repositoryUrl: repo,
        ref: "abc1234",
        editor: "github",
      }),
    ).toBeNull()
  })

  it("omits the line anchor when the frame has no line", () => {
    expect(
      sourceUrl({
        file: "app/models/user.rb",
        repositoryUrl: repo,
        ref: "abc1234",
        editor: "github",
      }),
    ).toBe("https://github.com/acme/widgets/blob/abc1234/app/models/user.rb")
  })

  it("escapes telemetry-controlled path syntax for web and local editors", () => {
    const hostileSyntax = { file: "app/models/café ?# user.rb", line: 12 }

    expect(
      sourceUrl({
        ...hostileSyntax,
        repositoryUrl: repo,
        ref: "abc1234",
        editor: "github",
      }),
    ).toBe(
      "https://github.com/acme/widgets/blob/abc1234/app/models/caf%C3%A9%20%3F%23%20user.rb#L12",
    )
    expect(
      sourceUrl({
        ...hostileSyntax,
        editor: "vscode",
        editorRoot: "/home/cole/my app",
      }),
    ).toBe(
      "vscode://file/home/cole/my%20app/app/models/caf%C3%A9%20%3F%23%20user.rb:12",
    )
  })

  it.each([
    "/etc/passwd",
    "C:/Windows/System32/drivers/etc/hosts",
    "C:\\Windows\\System32\\drivers\\etc\\hosts",
    "//server/share/secrets.txt",
    "\\\\server\\share\\secrets.txt",
    "../config/credentials.yml.enc",
    "app/../config/database.yml",
    "app/%2e%2e/config/database.yml",
    "app/%252e%252e/config/database.yml",
    "app/%252525252e%252525252e/config/database.yml",
    "%2fetc/passwd",
    "%252525252fetc/passwd",
    "app\\models\\user.rb",
    "app/models/user.rb%0ahttps://attacker.test",
  ])(
    "refuses a path that can escape the configured editor root: %s",
    (file) => {
      expect(
        sourceUrl({ file, editor: "vscode", editorRoot: "/home/cole/app" }),
      ).toBeNull()
    },
  )

  it("encodes a valid slash-containing branch as one ref segment", () => {
    expect(
      sourceUrl({
        ...frame,
        repositoryUrl: repo,
        ref: "feature/source#links",
        editor: "github",
      }),
    ).toBe(
      "https://github.com/acme/widgets/blob/feature%2Fsource%23links/app/models/user.rb#L12",
    )
  })

  it.each([
    "../main",
    "/main",
    "main/",
    "main..production",
    "feature/@{1}",
    "refs/heads/.hidden",
    "release.lock",
    "main?plain=1",
    "main\\evil",
  ])("refuses an unsafe source ref: %s", (ref) => {
    expect(
      sourceUrl({ ...frame, repositoryUrl: repo, ref, editor: "github" }),
    ).toBeNull()
  })

  it("retains self-managed GitHub and GitLab hosts", () => {
    expect(
      sourceUrl({
        ...frame,
        repositoryUrl: "https://github.acme.internal/platform/widgets",
        ref: "abc1234",
        editor: "github",
      }),
    ).toBe(
      "https://github.acme.internal/platform/widgets/blob/abc1234/app/models/user.rb#L12",
    )
    expect(
      sourceUrl({
        ...frame,
        repositoryUrl: "https://gitlab.acme.internal/platform/widgets",
        ref: "abc1234",
        editor: "gitlab",
      }),
    ).toBe(
      "https://gitlab.acme.internal/platform/widgets/-/blob/abc1234/app/models/user.rb#L12",
    )
  })
})

describe("commitUrl", () => {
  it("links a sha to its GitHub commit", () => {
    expect(commitUrl(repo, "abc1234")).toBe(
      "https://github.com/acme/widgets/commit/abc1234",
    )
  })

  it("links a sha to its GitLab commit", () => {
    expect(commitUrl("https://gitlab.com/acme/widgets", "abc1234")).toBe(
      "https://gitlab.com/acme/widgets/-/commit/abc1234",
    )
  })

  it("returns null for a repository host it cannot build URLs for", () => {
    expect(commitUrl("https://git.acme.test/widgets", "abc1234")).toBeNull()
  })

  it("returns null without a repository URL", () => {
    expect(commitUrl(null, "abc1234")).toBeNull()
  })

  it("encodes valid slash refs and refuses unsafe refs", () => {
    expect(commitUrl(repo, "release/2026-09")).toBe(
      "https://github.com/acme/widgets/commit/release%2F2026-09",
    )
    expect(commitUrl(repo, "abc123#diff")).toBe(
      "https://github.com/acme/widgets/commit/abc123%23diff",
    )
    expect(commitUrl(repo, "../main")).toBeNull()
  })
})

describe("compareUrl", () => {
  it("compares two refs on GitHub", () => {
    expect(compareUrl(repo, "aaa", "bbb")).toBe(
      "https://github.com/acme/widgets/compare/aaa...bbb",
    )
  })

  it("compares two refs on GitLab", () => {
    expect(compareUrl("https://gitlab.com/acme/widgets", "aaa", "bbb")).toBe(
      "https://gitlab.com/acme/widgets/-/compare/aaa...bbb",
    )
  })

  it("returns null when either ref is missing", () => {
    expect(compareUrl(repo, null, "bbb")).toBeNull()
    expect(compareUrl(repo, "aaa", null)).toBeNull()
  })

  it("encodes valid slash refs and refuses unsafe refs", () => {
    expect(compareUrl(repo, "release/2026-08", "release/2026-09")).toBe(
      "https://github.com/acme/widgets/compare/release%2F2026-08...release%2F2026-09",
    )
    expect(compareUrl(repo, "main?expand=1", "production")).toBeNull()
    expect(compareUrl(repo, "main", "production#files")).toBe(
      "https://github.com/acme/widgets/compare/main...production%23files",
    )
  })
})
