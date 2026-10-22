import { defineConfig } from "vitest/config"

// The browser client's tests. "@/lib/railwatch" is the path a host imports it
// by once the install generator has copied it into app/frontend/lib.
const client = new URL("./lib/generators/railwatch/install/templates/railwatch.ts", import.meta.url).pathname
const inertia = new URL("./spec/javascript/inertia-stub.ts", import.meta.url).pathname

export default defineConfig({
  resolve: {
    alias: {
      "@/lib/railwatch": client,
      "@inertiajs/react": inertia,
    },
  },
  test: {
    environment: "jsdom",
    include: ["spec/javascript/**/*.test.ts"],
  },
})
