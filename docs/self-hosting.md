# Self-hosting

This page is for sending telemetry to a Railwatch server you run
yourself instead of Railwatch Cloud.

The self-hosted server is [railwatch-rs](https://github.com/Rebulk/railwatch-rs)
(AGPL-3.0): one static binary on SQLite that serves many apps, with the
same dashboard, alerts, MCP server and JSON API as Railwatch Cloud. Its
install, configuration, backups and upgrades are documented in its
[SELF-HOST.md](https://github.com/Rebulk/railwatch-rs/blob/main/docs/SELF-HOST.md).
The gem doesn't care which server it talks to — point it at yours and
everything works the same.

For a single app, the [`railwatch-server`](https://github.com/Rebulk/railwatch-server)
gem runs that same server next to Puma and wires this gem to it, with no
host to set up; see [Getting started](getting-started.md#embedded-railwatch-server).
The rest of this page is for a server on its own host.

## Point the gem at your server

```ruby
# config/initializers/railwatch.rb
Railwatch.configure do |c|
  c.ingest_url = "https://telemetry.example.com"   # RAILWATCH_INGEST_URL
  c.token      = ENV["RAILWATCH_TOKEN"]
end
```

`ingest_url` defaults to `https://railwatch.rebulk.com`, so this is the one
setting a self-hosted install always needs; everything the gem sends —
records, ping, deploys — hangs off that host. Pass `--url=` to the
installer to have it written for you:

```sh
bin/rails generate railwatch:install --url=https://telemetry.example.com
```

The railwatch-rs installer prints both values (`RAILWATCH_INGEST_URL`,
`RAILWATCH_TOKEN`) when it finishes.

## Getting a token

railwatch-rs prints the first environment's token once, at the end of
its install. Each further environment (`production`, `staging` — one
token each) gets its own, created from the dashboard or with
`sudo railwatch env create <name>`. A token is shown once; a lost one is
replaced, not recovered.

```sh
bin/rails railwatch:token    # prints the URL to create/copy a token
```

## Check the connection

```sh
bin/rails railwatch:status   # pings {ingest_url}/ingest/ping with your token
bin/rails railwatch:doctor   # the full checklist: token, URL, reachability, wiring
```

`railwatch:status` aborts if the token is unset or the host is unreachable,
so it works as a post-deploy smoke test.
[`troubleshooting.md`](troubleshooting.md) covers each doctor line.

## MCP

Your server serves its own MCP endpoint at `<ingest host>/mcp` —
`https://telemetry.example.com/mcp` for the example above. It authenticates
with a per-user API token generated from Settings → Profile, the same
token the public JSON API at `/api/v1` uses. See
[`ai-and-mcp.md`](ai-and-mcp.md) for every client's configuration block.
