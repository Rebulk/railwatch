# Self-hosting

This page is for sending telemetry to a Railwatch Cloud you run
yourself. An [embedded](embedded.md) install keeps everything inside
your app and needs none of it.

Railwatch Cloud is a Rails app you can run yourself. The gem doesn't care
which install it talks to — point it at yours and everything works the
same.

## Point the gem at your platform

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
installer to have it written for you (it implies `--cloud`):

```sh
bin/rails generate railwatch:install --url=https://telemetry.example.com
```

To keep an embedded install and mirror it to your platform, set
`RAILWATCH_INGEST_URL` and `RAILWATCH_TOKEN` and turn on
[export](embedded.md#three-ways-to-run-it) instead.

## Getting a token

On your install: sign up, create an application, then create an
environment inside it (`production`, `staging` — one token each). The
token is shown once, right after you create the environment; a lost one
is rotated from the environment's settings, not recovered.

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

Your install serves its own MCP endpoint at `<ingest host>/mcp` —
`https://telemetry.example.com/mcp` for the example above. It authenticates
with a per-user API token generated from Settings → Profile, the same
token the public JSON API at `/api/v1` uses. See
[`ai-and-mcp.md`](ai-and-mcp.md) for every client's configuration block.

## Running the platform

Railwatch Cloud's backend is not part of this gem repository. Licensed
self-hosted customers receive separate platform deployment, backup, retention,
quota, and restore documentation from Rebulk.
