import { configure } from "@/routes"

// The path the dashboard is served under, from the layout's
// <meta name="railwatch-mount">: the embedded engine's mount point
// (request.script_name), or the base path of a Railwatch server mounted
// inside another app. "" without the tag (the hosted platform) or for
// anything that is not one absolute path: "//host" or "https://..." would
// point every link at another origin.
export function mountPath(doc: Document = document): string {
  const raw =
    doc.querySelector<HTMLMetaElement>('meta[name="railwatch-mount"]')
      ?.content ?? ""
  const path = raw.trim().replace(/\/+$/, "")
  return /^\/(?![/\\])/.test(path) ? path : ""
}

// Every route helper carries the mount point (js-routes' script_name).
// Returns the mount, "" when there is none and nothing changed.
export function applyMount(doc: Document = document): string {
  const mount = mountPath(doc)
  if (mount) configure({ default_url_options: { script_name: mount } })
  return mount
}
