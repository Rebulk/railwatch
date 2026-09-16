// Builds the dashboard the gem ships. Every asset URL is rooted at the
// engine's mount plus its static prefix (Railwatch::DashboardAssets), and
// the output lands in public/railwatch so `gem build` packages it. Node is
// needed here, at release time, never in a host application.
import tailwindcss from "@tailwindcss/vite"
import react from "@vitejs/plugin-react"
import rails from "rails-vite-plugin"
import { defineConfig } from "vite"

export default defineConfig({
  base: "/railwatch/assets/",
  publicDir: "app/frontend/public",
  build: { outDir: "public/railwatch", emptyOutDir: true },
  plugins: [
    react({ babel: { plugins: ["babel-plugin-react-compiler"] } }),
    tailwindcss(),
    rails({ sourceDir: "app/frontend", buildDirectory: "railwatch" }),
  ],
})
