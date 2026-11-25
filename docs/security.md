# Client-side security review

This review covers the open-source gem that runs in a customer's Rails
application. Railwatch Cloud is a separate service and is outside this review.

## Dashboard gate (railwatch-sidecar)

The gem serves no dashboard. With the separate `railwatch-sidecar` gem
installed, a dashboard showing every query, log line and exception the app
recorded is proxied at `/railwatch`, and its gate is this gem's settings.
HTTP Basic authentication is on by default. With no credentials configured,
every dashboard request is 401 in every environment except development,
where it is open. Credentials, once set, apply in development too. An app
that turns Basic off gates the dashboard with its own `base_controller_class`,
which railwatch-sidecar's proxy controller inherits from. See
[Configuration](configuration.md#dashboard-gate-railwatch-sidecar).

## Transport

`Railwatch::Transport::Http` sends gzip NDJSON with `Net::HTTP`. HTTPS explicitly
sets OpenSSL's `VERIFY_PEER`; a spec pins that setting. The transport does not
implement redirect handling, so a redirect response is treated as a permanent
delivery failure and its target is never followed.

Plain HTTP is refused unless the ingest host is `localhost`, `127.0.0.1`, or
`::1`, or `RAILWATCH_ALLOW_HTTP=true` is explicitly set. Refusal does not raise
into application code: delivery returns a failed result, `railwatch:doctor`
reports the policy, and Rails logs a warning during boot. Deploy markers and
source-map uploads enforce the same URL policy.

## Data capture and redaction

The defaults are defined in `Railwatch::Configuration` and covered by
configuration and record specs:

- Header names in `redact_headers` are filtered case-insensitively. A broader
  `SENSITIVE_HEADER_NAME` expression also filters credential-shaped names such
  as API keys, tokens, secrets, signatures, and authorization headers.
- Parameter filtering combines `redact_params` with the host application's
  `Rails.application.config.filter_parameters`.
- `capture_sql_values` is false. Query records contain normalized SQL shapes;
  Active Record binds are not sent.
- `capture_request_payload` is false. When enabled, filtered request params are
  attached only to a request that raised, never to a successful request.
- `capture_exception_locals` is false. When enabled, at most 25 locals are
  converted with `inspect`, truncated to 200 characters, and parameter
  filtered: by the local's name, and by key inside a local that is a Hash,
  an Array or request parameters (so `attrs = { password: ... }` ships as
  `[FILTERED]` under `password`). A key the header rules name as a
  credential (`Authorization`, `Cookie`, `X-Api-Key`, `redact_headers`) is
  masked too; span attributes, `Rails.event` payloads (Struct and Data
  events by member), request parameters given as context, and LLM tool
  arguments and results get the same key filter. A secret held in a plain String under a
  name the filter does not match, or printed by another object's own
  `inspect`, is sent as it is; leave this off where that can happen.
  `Locals.inspect_value` rescues an `inspect` implementation that
  raises; this behavior is covered by an exception-record spec.
- `capture_exception_source` is true. Source lines surrounding in-application
  backtrace frames are recorded and sent to the configured server. Disable it if source context is outside the
  application's telemetry policy.

Log record messages are sent as supplied to `Rails.logger`, with one
exception: every URL in a line is cleaned the way the request record's own
URLs are (userinfo, query and fragment dropped, this app's credential route
segments filtered, known third-party credential paths masked), so Rails'
own `Redirected to <url>` and routing-error lines do not repeat what
`redirect_to` and `path` filter. At most 20 URLs per line are cleaned in
full; the rest keep only scheme and host. The same cleaning applies to
exception messages and `outgoing_request.error` (Faraday's `status 401 for
GET <url>`), and with `capture_sql_values` off a database error's message
has the statement it repeats masked as the `query` record masks it.
Railwatch does not attempt to parse and partially filter `key=value` text
in a log line, because doing so would be incomplete and could give a false assurance. Applications must not
log secrets; `Railwatch.redact_logs` can implement an application-specific scrub,
and `Railwatch.reject_logs` or `RAILWATCH_IGNORE_LOGS=true` can omit log records.

A `command` record's invocation (rake task arguments, inline `rails
runner` code) gets the same URL cleaning, and there the value of a
`name=value`, `name: value` or `name => value` pair whose name the
parameter filter or the header rules name is masked, as is a rake argument
the task declares under such a name. That is the one place key/value text
is parsed, because an operator types it rather than an application
logging it, and inline runner code is also every record's
`execution_preview`. It is still a best effort: a secret under a neutral
name (`Vendor.connect("hunter2")`) is sent. `Railwatch.redact_commands`
hooks run on that preview too, so a hook that masks `command` leaves no
copy on the run's other records.

`railwatch:authentication:configure` decrypts the environment's Rails
credentials. If it fails (an unwritable config directory, a full disk, a
file that does not parse) it raises `Railwatch::Authentication::Error`
from a frame whose only local is the message, with no `cause`, so that
`capture_exception_locals` never records the frame that held the
decrypted document.

## Browser beacon

`POST /railwatch/beacon` is the gem's only inbound endpoint that is
unauthenticated by design. It
is rate-limited per client IP through the Rails cache (120 requests per minute
by default), limited to a 256 KiB body, and capped at 50 visits and 50 errors
per request. Nested error stacks, messages, breadcrumbs, context, visit partial
keys, session ids, URLs, and other strings have count or length ceilings.

Specs verify that an oversized body is rejected, unexpected top-level and
nested scalar/array/object shapes are ignored, malformed UTF-8 does not produce
a 500, and accepted strings are converted to valid UTF-8. Payload-processing
errors are discarded with a debug diagnostic rather than raised into the host
application. Rack and Rails still parse the request before controller code, so
operators should also enforce an HTTP request-body limit at the reverse proxy
for protection before application allocation.

The endpoint intentionally has no authenticity token: it receives browser
telemetry without exposing the application's ingest token. Rate limiting is
quota-abuse mitigation, not authentication. Applications can disable it with
`beacon_enabled = false` when browser telemetry is not used.

## Wire-data use

A source audit found no wire value passed to `eval`, `instance_eval`,
`constantize`, dynamic `send`, a shell command, backticks, or a file-path read.
The gem's backtick use runs a fixed `git log` command for deploy metadata. File
reads use fixed application/configuration paths or exception backtrace paths;
browser-provided frame paths are never read from disk. Ingest responses are
JSON-parsed and validated as acknowledgement counts only.

## Token handling

The install generator accepts hidden prompt or stdin input and never prints a
token value. Diagnostics show only a short prefix and total length. The
generator writes a token to `.env` only when Git confirms the file is ignored,
and specs assert that command output omits the complete token. Tokens remain an
application/deployment secret and must not be committed.

## Application responsibilities

- Review `redact_headers`, `redact_params`, and Rails `filter_parameters` for
  application-specific credentials and personal data.
- Keep secrets out of exception messages, log text, source files, tenant ids,
  user resolvers, custom context, and command lines (rake arguments, inline
  `rails runner` code).
- With railwatch-sidecar, set dashboard credentials (or your own gate) before
  deploying; see [Configuration](configuration.md#dashboard-gate-railwatch-sidecar).
- Use HTTPS in production and keep TLS verification enabled.
- Put a request-body limit at the reverse proxy when the public beacon is
  enabled, and choose a shared cache if rate limits must span processes.
- Review every opt-in capture setting before enabling it in production.
