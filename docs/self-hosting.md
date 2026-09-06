# Self-hosting

Lantern Cloud is a Rails app you can run yourself. The gem doesn't care
which install it talks to — point it at yours and everything works the
same.

## Point the gem at your platform

```ruby
# config/initializers/lantern.rb
Lantern.configure do |c|
  c.ingest_url = "https://telemetry.example.com"   # LANTERN_INGEST_URL
  c.token      = ENV["LANTERN_TOKEN"]
end
```

`ingest_url` defaults to `https://lantern.rebulk.com`, so this is the one
setting a self-hosted install always needs; everything the gem sends —
records, ping, deploys — hangs off that host. Pass `--url=` to the
installer to have it written for you:

```sh
bin/rails generate lantern:install --url=https://telemetry.example.com
```

## Getting a token

On your install: sign up, create an application, then create an
environment inside it (`production`, `staging` — one token each). The
token is shown once, right after you create the environment; a lost one
is rotated from the environment's settings, not recovered.

```sh
bin/rails lantern:token    # prints the URL to create/copy a token
```

## Check the connection

```sh
bin/rails lantern:status   # pings {ingest_url}/ingest/ping with your token
bin/rails lantern:doctor   # the full checklist: token, URL, reachability, wiring
```

`lantern:status` aborts if the token is unset or the host is unreachable,
so it works as a post-deploy smoke test.
[`troubleshooting.md`](troubleshooting.md) covers each doctor line.

## MCP

Your install serves its own MCP endpoint at `<ingest host>/mcp` —
`https://telemetry.example.com/mcp` for the example above. It authenticates
with a per-user API token generated from Settings → Profile, the same
token the public JSON API at `/api/v1` uses. See
[`ai-and-mcp.md`](ai-and-mcp.md) for every client's configuration block.

## Running the platform

Lantern Cloud's backend is not part of this gem repository. Licensed
self-hosted customers receive separate platform deployment, backup, retention,
quota, and restore documentation from Rebulk.
