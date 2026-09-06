# Client-side security review

This review covers the open-source gem that runs in a customer's Rails
application. Nightrail Cloud is a separate service and is outside this review.

## Transport

`Nightrail::Transport::Http` sends gzip NDJSON with `Net::HTTP`. HTTPS explicitly
sets OpenSSL's `VERIFY_PEER`; a spec pins that setting. The transport does not
implement redirect handling, so a redirect response is treated as a permanent
delivery failure and its target is never followed.

Plain HTTP is refused unless the ingest host is `localhost`, `127.0.0.1`, or
`::1`, or `NIGHTRAIL_ALLOW_HTTP=true` is explicitly set. Refusal does not raise
into application code: delivery returns a failed result, `nightrail:doctor`
reports the policy, and Rails logs a warning during boot. Deploy markers and
source-map uploads enforce the same URL policy.

## Data capture and redaction

The defaults are defined in `Nightrail::Configuration` and covered by
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
  filtered. `Locals.inspect_value` rescues an `inspect` implementation that
  raises; this behavior is covered by an exception-record spec.
- `capture_exception_source` is true. Source lines surrounding in-application
  backtrace frames are sent to Nightrail Cloud. Disable it if source context is
  outside the application's telemetry policy.

Log record messages are sent exactly as supplied to `Rails.logger`. Nightrail
does not attempt to parse and partially filter `key=value` text because doing
so would be incomplete and could give a false assurance. Applications must not
log secrets; `Nightrail.redact_logs` can implement an application-specific scrub,
and `Nightrail.reject_logs` or `NIGHTRAIL_IGNORE_LOGS=true` can omit log records.

## Browser beacon

`POST /nightrail/beacon` is the gem's only inbound unauthenticated endpoint. It
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
  user resolvers, and custom context.
- Use HTTPS in production and keep TLS verification enabled.
- Put a request-body limit at the reverse proxy when the public beacon is
  enabled, and choose a shared cache if rate limits must span processes.
- Review every opt-in capture setting before enabling it in production.
