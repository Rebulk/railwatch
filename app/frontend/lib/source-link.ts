// Builds "open this file" URLs: either into the application's repository on
// GitHub/GitLab (pinned to the deploy's git SHA when we have one, else the
// default branch) or into the user's local editor via its URL scheme. The
// repository URL comes from the application, the editor and local checkout
// path from the user's profile.

export interface SourceUrlOptions {
  file: string
  line?: number | null
  repositoryUrl?: string | null
  ref?: string | null
  defaultBranch?: string | null
  editor?: string | null
  editorRoot?: string | null
}

function present(value: string | null | undefined): string | null {
  const trimmed = (value ?? "").trim()
  return trimmed === "" ? null : trimmed
}

function hasControlCharacters(value: string): boolean {
  return [...value].some((character) => {
    const code = character.codePointAt(0) ?? 0
    return code <= 0x1f || (code >= 0x7f && code <= 0x9f)
  })
}

function decodeToFixedPoint(value: string): string | null {
  let decoded = value

  try {
    // Each useful decode consumes at least one percent escape, so an
    // input-length bound reaches a fixed point without an arbitrary pass cap.
    for (let remaining = value.length + 1; remaining > 0; remaining -= 1) {
      const next = decodeURIComponent(decoded)
      if (next === decoded) return decoded
      decoded = next
    }
  } catch {
    return null
  }

  return null
}

function encodePathSegments(value: string): string | null {
  try {
    return value.split("/").map(encodeURIComponent).join("/")
  } catch {
    return null
  }
}

function isAbsolutePath(value: string): boolean {
  return (
    value.startsWith("/") ||
    value.startsWith("\\") ||
    /^[a-z]:[\\/]/iu.test(value)
  )
}

function sourcePath(value: string | null | undefined): {
  raw: string
  encoded: string
} | null {
  const raw = present(value)
  if (!raw || isAbsolutePath(raw)) return null

  const decoded = decodeToFixedPoint(raw)
  if (!decoded || isAbsolutePath(decoded)) return null

  if (
    decoded.includes("\\") ||
    hasControlCharacters(decoded) ||
    /%(?:2e|2f|5c)/iu.test(decoded) ||
    decoded
      .split("/")
      .some((segment) => segment === "" || segment === "." || segment === "..")
  )
    return null

  const encoded = encodePathSegments(raw)
  return encoded ? { raw, encoded } : null
}

function encodedRoot(value: string | null | undefined): {
  raw: string
  encoded: string
} | null {
  const raw = present((value ?? "").replace(/\/+$/, ""))
  if (!raw) return null
  const encoded = encodePathSegments(raw)
  return encoded ? { raw, encoded } : null
}

function gitRef(value: string | null | undefined): {
  raw: string
  encoded: string
} | null {
  const raw = present(value)
  if (
    !raw ||
    raw === "@" ||
    raw.startsWith("/") ||
    raw.endsWith("/") ||
    raw.endsWith(".") ||
    raw.includes("//") ||
    raw.includes("..") ||
    raw.includes("@{") ||
    raw.includes("[") ||
    hasControlCharacters(raw) ||
    /[ ~^:?*\\]/u.test(raw) ||
    raw
      .split("/")
      .some(
        (component) => component.startsWith(".") || component.endsWith(".lock"),
      )
  )
    return null

  try {
    return { raw, encoded: encodeURIComponent(raw) }
  } catch {
    return null
  }
}

// "https://github.com/org/repo.git/" -> "https://github.com/org/repo"
function repository(url: string | null | undefined): string | null {
  return present((url ?? "").replace(/\/+$/, "").replace(/\.git$/, ""))
}

function host(url: string | null | undefined): "github" | "gitlab" | null {
  const repo = repository(url)
  if (!repo) return null
  if (repo.includes("gitlab")) return "gitlab"
  if (repo.includes("github")) return "github"
  return null
}

export function sourceUrl({
  file,
  line,
  repositoryUrl,
  ref,
  defaultBranch,
  editor,
  editorRoot,
}: SourceUrlOptions): string | null {
  const path = sourcePath(file)
  if (!path) return null

  if (editor === "github" || editor === "gitlab") {
    const repo = repository(repositoryUrl)
    const at = gitRef(present(ref) ?? defaultBranch)
    if (!repo || !at) return null
    const blob = editor === "gitlab" ? "-/blob" : "blob"
    return `${repo}/${blob}/${at.encoded}/${path.encoded}${line ? `#L${line}` : ""}`
  }

  const root = encodedRoot(editorRoot)
  if (!root) return null
  const target = `${root.raw}/${path.raw}`
  const encodedTarget = `${root.encoded}/${path.encoded}`
  const suffix = line ? `:${line}` : ""
  switch (editor) {
    case "vscode":
      return `vscode://file${encodedTarget}${suffix}`
    case "cursor":
      return `cursor://file${encodedTarget}${suffix}`
    case "zed":
      return `zed://file${encodedTarget}${suffix}`
    case "rubymine":
      return `jetbrains://rubymine/navigate/reference?project=&path=${encodeURIComponent(`${target}${suffix}`)}`
    case "textmate":
      return `txmt://open?url=${encodeURIComponent(`file://${target}`)}${line ? `&line=${line}` : ""}`
    default:
      return null
  }
}

export function commitUrl(
  repositoryUrl: string | null | undefined,
  sha: string | null | undefined,
): string | null {
  const repo = repository(repositoryUrl)
  const commit = gitRef(sha)
  if (!repo || !commit) return null
  switch (host(repositoryUrl)) {
    case "github":
      return `${repo}/commit/${commit.encoded}`
    case "gitlab":
      return `${repo}/-/commit/${commit.encoded}`
    default:
      return null
  }
}

export function compareUrl(
  repositoryUrl: string | null | undefined,
  from: string | null | undefined,
  to: string | null | undefined,
): string | null {
  const repo = repository(repositoryUrl)
  const start = gitRef(from)
  const end = gitRef(to)
  if (!repo || !start || !end) return null
  switch (host(repositoryUrl)) {
    case "github":
      return `${repo}/compare/${start.encoded}...${end.encoded}`
    case "gitlab":
      return `${repo}/-/compare/${start.encoded}...${end.encoded}`
    default:
      return null
  }
}
