# Production browser source maps

Nightrail can resolve minified browser errors to their original source files,
lines, function names and embedded code. Maps stay in the environment's
private telemetry database; Nightrail never downloads a `sourceMappingURL`.

Enable hidden source maps in Vite:

```ts
export default defineConfig({
  // Keep your existing plugins and options.
  build: { sourcemap: "hidden" },
})
```

After building, upload the maps **before publishing the image or assets**:

```sh
NIGHTRAIL_DEPLOY="$RELEASE_SHA" bin/rails 'nightrail:sourcemaps[public,true]'
```

The task uses the application's `NIGHTRAIL_TOKEN` and `NIGHTRAIL_INGEST_URL`.
Use the same deploy value the running application reports. The first argument
is the public URL root: `public/vite/assets/index-abc.js.map` becomes
`vite/assets/index-abc.js`, matching `/vite/assets/index-abc.js` in a browser
stack. The optional second argument `true` deletes each map only after the
server acknowledges its upload. Without it, files are retained. A failed
upload fails the task and leaves that file on disk. Hidden maps still exist
on disk, so the deletion step belongs before publishing public assets.

The equivalent environment options are `NIGHTRAIL_SOURCEMAPS_DIR=public` and
`NIGHTRAIL_SOURCEMAPS_DELETE=true`. The generated Kamal post-deploy hook also
accepts `--sourcemaps` or `NIGHTRAIL_SOURCEMAPS=true`, using local artifacts on
the deployer and `KAMAL_VERSION` as the deploy. That hook reports failures
without failing the deployment. Build-time upload is preferable because it
removes maps before assets become public.

Uploads accept flat Source Map v3 files (Vite's output), up to 10 MiB each,
500,000 mapping segments and 200,000 generated lines. Indexed `sections`
maps and remote references are unsupported. Embedded `sourcesContent`
provides snippets; it is optional. No local source files are opened by the
server. Maps for the current deploy and releases referenced by retained
requests, jobs, exceptions or sessions stay available. Maps for inactive
releases expire once their last update is older than the environment's raw
telemetry retention; replacing a map renews that window.

New default browser issue fingerprints use the resolved original location
when a map is already available. Custom fingerprints are preserved. Late
uploads improve existing stack displays, Copy for AI, API issue details and
MCP `get_issue`, while existing occurrences keep their original grouping.
Missing maps or columns fall back to the raw stack. Upgrade the gem for
new browser occurrences to include columns; older gem versions discarded
them and cannot resolve minified locations accurately.

For a custom release uploader, POST the raw `.map` bytes to
`/ingest/sourcemaps` with `Content-Type: application/octet-stream`,
`Authorization: Bearer lt_...`, `X-Nightrail-Deploy`, and
`X-Nightrail-Filename` (the generated JavaScript URL path without a leading
slash). A successful response is HTTP 201 with
`{"ok":true,"filename":"vite/assets/index-abc.js","bytes":1234}`.
