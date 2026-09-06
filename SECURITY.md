# Security policy

## Supported versions

Security fixes are released on the latest published Lantern version. Upgrade
to the newest release before reporting an issue against an older version.

| Version | Supported |
|---|---|
| Latest release | Yes |
| Older releases | No |

## Reporting a vulnerability

Please do not open a public issue. Use GitHub private vulnerability reporting
for this repository, or email [security@rebulk.com](mailto:security@rebulk.com).
Include affected versions, reproduction steps, and impact when possible.

## Data boundary

The gem runs inside the customer Rails process and sends telemetry outward to
the configured Lantern Cloud ingest URL. It does not accept commands from
Lantern Cloud and never writes to the application's database. Its one inbound
route is the unauthenticated browser beacon mounted under `/lantern/beacon`;
that route is rate- and size-limited.

Telemetry may include request metadata, filtered headers, normalized SQL,
logs, exception messages and backtraces, and source lines surrounding an
exception. Source capture is on by default because it supplies crash context;
disable it with `capture_exception_source = false` or
`LANTERN_CAPTURE_EXCEPTION_SOURCE_CODE=false`. Request payloads, exception
locals, SQL literal values, job arguments, upstream error bodies, attachments,
and profiles are either off by default or require an explicit application
call. Log messages are sent as the application wrote them and are not parsed
for embedded secrets.

See [the client-side security review](docs/security.md) for the verified
controls, remaining application responsibilities, and transport details.
