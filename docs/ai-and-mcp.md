# AI assistants and MCP

Lantern Cloud is an [MCP](https://modelcontextprotocol.io) server. Point
Claude Code, Claude Desktop, Cursor, VS Code, or Zed at it and the assistant
sitting in your editor can read the same production data your dashboards
show: issues and their stack traces, slow routes, the queries and N+1s
behind them, stored query plans, stack profiles, logs, deploys, and
crash-free rates per release. It can also write — resolve an issue, set a
priority, leave a comment — and every write is signed with your user and the
agent's name in the issue's activity feed.

The endpoint is `<your ingest host>/mcp`. For the hosted platform that's
`https://lantern.rebulk.com/mcp`; if you self-host, it is your own host (see
[`self-hosting.md`](self-hosting.md)). The gem knows which one you're on:

```sh
bin/rails lantern:mcp
```

prints every block below with your platform's host already filled in.

## 1. Get a token

MCP tokens are **per person**, not per application: sign in to the platform,
go to **Settings → Profile → "API & MCP token"**, and press *Generate token*.
The token starts with `lnt_` and is shown once. It can reach every account
your user belongs to, and nothing else.

This is a different token from the `lt_...` ingest token the gem uses. The
ingest token writes telemetry for one environment; the MCP token reads it
back as you.

That page also renders the blocks below with the real token substituted in,
each with a copy button — so the fastest path is: generate, copy, paste.

## 2. Connect a client

Everything below uses `https://lantern.rebulk.com/mcp`; substitute your own
host if you self-host, and `lnt_your_token_here` for the token.

### Claude Code

```sh
claude mcp add lantern --transport http https://lantern.rebulk.com/mcp \
  --header "Authorization: Bearer lnt_your_token_here"
```

### Claude Desktop

Claude Desktop speaks stdio, so it needs the `mcp-remote` bridge. In
`claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "lantern": {
      "command": "npx",
      "args": [
        "-y",
        "mcp-remote",
        "https://lantern.rebulk.com/mcp",
        "--header",
        "Authorization: Bearer lnt_your_token_here"
      ]
    }
  }
}
```

### Cursor

`.cursor/mcp.json` in the project, or `~/.cursor/mcp.json` for every project:

```json
{
  "mcpServers": {
    "lantern": {
      "url": "https://lantern.rebulk.com/mcp",
      "headers": { "Authorization": "Bearer lnt_your_token_here" }
    }
  }
}
```

### VS Code

`.vscode/mcp.json` in the workspace:

```json
{
  "servers": {
    "lantern": {
      "type": "http",
      "url": "https://lantern.rebulk.com/mcp",
      "headers": { "Authorization": "Bearer lnt_your_token_here" }
    }
  }
}
```

### Zed

`settings.json`, also through the `mcp-remote` bridge:

```json
{
  "context_servers": {
    "lantern": {
      "source": "custom",
      "command": "npx",
      "args": [
        "-y",
        "mcp-remote",
        "https://lantern.rebulk.com/mcp",
        "--header",
        "Authorization: Bearer lnt_your_token_here"
      ]
    }
  }
}
```

### Check it without a client

```sh
curl -sS https://lantern.rebulk.com/mcp \
  -H "Authorization: Bearer lnt_your_token_here" \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

A JSON body listing tools means the token works. A `401` means it doesn't.

`GET https://lantern.rebulk.com/mcp` and
`GET https://lantern.rebulk.com/.well-known/mcp.json` describe the server —
name, version, protocol version, transport, tool and prompt names, and how
to authenticate — with no token at all, for clients that probe a host before
they're configured.

## 3. Tools

Every tool returns JSON as the text body of a single content block. **All
durations are milliseconds.** Every `window` argument takes `1h`, `6h`,
`24h`, `7d`, or `30d`, and defaults to `24h`.

| Tool | Arguments | Returns |
|---|---|---|
| `list_applications` | — | applications, their account, and their environments. Start here — everything else takes the `application_slug` and `environment` this returns. |
| `list_issues` | `application_slug?`, `environment?`, `status?` (`open`/`resolved`/`ignored`, default `open`), `limit?` | issues with key, title, kind, status, priority, occurrence and affected-user counts, culprit, first/last seen. |
| `get_issue` | `key` | one issue plus the sample occurrence: exception class, message, stack frames, and the execution it happened inside. |
| `update_issue` | `key`, `status?`, `priority?`, `assignee_email?`, `agent?` | the updated issue. Writes an activity entry attributed to your user and `agent`. |
| `add_comment` | `key`, `body`, `agent?` | the created comment, attributed the same way. |
| `list_slow_routes` | `application_slug`, `environment`, `window?` | the 20 slowest routes by p95, each with `group_hash`, count, errors, `p95_ms`. |
| `get_route` | `application_slug`, `environment`, `route` or `group_hash`, `window?` | one route's count/errors, p50/p95/p99/max, its slowest individual requests, the slowest queries those requests ran, and each N+1 with a concrete Active Record fix. |
| `search_requests` | `application_slug`, `environment`, `q?`, `window?`, `limit?` | individual requests. `q` is the dashboard's filter grammar: `method:GET`, `route:/checkout`, `status:500` or `status:5xx`, `deploy:…`, `tenant:…`, `user:…`, `min_ms:250`; bare words match the route name. |
| `get_execution` | `application_slug`, `environment`, `execution_id` | one execution and its full child timeline — every query, cache read, log line, outgoing request, view render, and exception, each offset in ms from the start. |
| `explain_query` | `application_slug`, `environment`, `group_hash`, `window?` | the stored query plan for a query group, with the SQL and the sample's duration. `explain` is null unless the app sets `LANTERN_CAPTURE_QUERY_EXPLAIN`. `sql` is the normalized shape unless the app also sets `LANTERN_CAPTURE_SQL_VALUES`. |
| `get_profile` | `application_slug`, `environment`, `profile_id?`, `execution_id?`, `limit?` | the hottest frames of a stack profile — self and total samples, each with a percentage. |
| `search_logs` | `application_slug`, `environment`, `q`, `level?`, `limit?` | matching log lines, each with the `execution_id` to expand with `get_execution`. |
| `list_tenants` | `application_slug`, `environment`, `window?`, `q?` | your app's own tenants (whatever it passes to `Lantern.context(tenant:)`) with request, error, job, exception, and user counts. |
| `recent_deploys` | `application_slug`, `environment` | the 20 most recent deploys with ref, name, time, and link. |
| `release_health` | `application_slug`, `environment`, `window?` | crash-free session rate, crash-free user rate, and adoption per release. |
| `list_alerts` | `application_slug?`, `event?`, `status?`, `limit?` | fired alerts: which rule, which issue, which integration, and whether delivery succeeded. |

## 4. Prompts

Three canned workflows. A prompt is a plan, not an answer: it tells the
assistant which tools to call in which order and what to do with each
result, so its first turn is spent working rather than asking you which tool
exists.

| Prompt | Arguments | What it does |
|---|---|---|
| `triage_issue` | `key` | Reads the issue and its sample, pulls the execution timeline around the failure, searches the logs for the same failure elsewhere, lines `first_seen_at` up against recent deploys, then reports what breaks, for whom, how often, and the smallest fix. It will comment and set a priority; it is told not to resolve. |
| `slow_route` | `application_slug`, `environment`, `route`, `window?` | Pulls the route summary, its slow queries and N+1s, the stored plan for each query group, and a stack profile if one exists, then reports the indexes and `includes` to add, ordered by expected saving, quoting measured milliseconds. |
| `daily_summary` | `application_slug`, `environment`, `window?` | New issues, spiking issues, deploys, release-health movement, the worst routes, and what already alerted — leading with the one thing worth acting on. |

In Claude Code these appear as slash commands once the server is connected.

## 5. Resources

The server also publishes documents an assistant can read without a tool
call:

| URI | Contents |
|---|---|
| `lantern://applications` | Every application and environment the token can see. |
| `lantern://applications/<slug>/environments/<name>/summary` | Request and job volume, p95, errors, open issue count, last-seen time, and deploys, over the last 24 hours, with the previous 24 hours alongside for comparison. |
| `lantern://docs/<name>` | Lantern's own documentation — `readme`, `getting-started`, `configuration`, `records`, `testing`, `replacing-sentry`, `troubleshooting`, `faq`, and the rest. An assistant that doesn't know an option can look it up instead of guessing. |

## 6. What an assistant can and can't do

- **Scope.** A token reaches exactly the accounts its user belongs to.
  Revoke it by regenerating: Settings → Profile → *Regenerate token*
  invalidates the old one immediately.
- **Writes.** Only three things write: `update_issue`, `add_comment`, and
  the activity entries they create. There is no tool that deletes anything,
  changes billing, or touches your Rails app.
- **Attribution.** Every write records your user *and* the `agent` name the
  client sent, so "who resolved this" has an honest answer in the UI.
- **Payloads.** Tools return what the dashboards show, which is what the gem
  shipped. If you don't want request parameters or job arguments leaving
  your app, they never arrive here in the first place — see the redaction
  and opt-in capture settings in
  [`configuration.md`](configuration.md).

## 7. Agents working on your app

Separately from the MCP server, the gem ships two files for coding agents
working *in a Rails app that uses Lantern*:

- [`../llms.txt`](../llms.txt) — the [llmstxt.org](https://llmstxt.org)
  index: one paragraph on what Lantern is, then every document with a
  one-line description.
- [`../AGENTS.md`](../AGENTS.md) — how to install it, the facade methods,
  the spec matchers, `lantern:doctor`, and this MCP hookup, in under 120
  lines.

Copy either into your own app's repo to give its agent the same context.

## See also

- [`getting-started.md`](getting-started.md) — install, token, first request.
- [`self-hosting.md`](self-hosting.md) — pointing the gem, and this endpoint,
  at your own platform.
- [`troubleshooting.md`](troubleshooting.md) — when something isn't
  reporting.
