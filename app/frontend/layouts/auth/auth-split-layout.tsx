import { Link } from "@inertiajs/react"
import type { PropsWithChildren } from "react"

import AppWordmark from "@/components/app-wordmark"
import {
  HERO_HEADLINE_ACCENT,
  HERO_HEADLINE_LEAD,
  HERO_SUBHEAD,
} from "@/components/marketing/copy"
import { Signal, Track } from "@/components/railwatch/empty-state"
import { rootPath } from "@/routes"

interface AuthLayoutProps {
  title?: string
  description?: string
}

// A resting train on the line under the product: the same three cars and
// gold tail lamp the homepage loop and the social image draw.
function Train({ className }: { className?: string }) {
  return (
    <svg
      aria-hidden
      viewBox="-60 -8 120 16"
      className={className}
      fill="currentColor"
    >
      <rect x="-56" y="-7" width="30" height="14" rx="3" />
      <rect x="-21" y="-7" width="34" height="14" rx="3" />
      <rect x="18" y="-7" width="38" height="14" rx="3" />
      <rect
        x="50"
        y="-4"
        width="4"
        height="8"
        rx="1"
        className="text-primary"
        fill="currentColor"
      />
    </svg>
  )
}

export default function AuthSplitLayout({
  children,
  title,
  description,
}: PropsWithChildren<AuthLayoutProps>) {
  return (
    <div className="grid min-h-dvh lg:grid-cols-2">
      {/* Brand panel: the social image's composition. The Requests screen
          sits tilted on a line that runs across the lower third, the train
          rests at a clear signal beneath it, and the headline closes the
          panel. Always navy, whatever the visitor's appearance setting. */}
      <div className="dark relative hidden flex-col justify-between overflow-hidden border-r border-white/10 bg-[#020618] p-10 text-white lg:flex">
        <div
          className="pointer-events-none absolute inset-0"
          aria-hidden
          style={{
            background:
              "radial-gradient(600px 400px at 70% 45%, rgba(253,193,26,.07), transparent 65%), radial-gradient(500px 400px at 10% 10%, rgba(30,42,69,.9), transparent 65%)",
          }}
        />
        <div
          className="pointer-events-none absolute inset-x-0 top-[71%] h-14 -translate-y-1/2"
          aria-hidden
        >
          <Track className="[mask-image:linear-gradient(to_right,transparent,black_12%,black_88%,transparent)] text-white/30 md:[mask-image:linear-gradient(to_right,transparent,black_12%,black_88%,transparent)]" />
          <Train className="absolute top-1/2 left-[40%] h-4 w-30 -translate-y-1/2 text-white/50" />
          <Signal
            aspect="clear"
            className="left-[calc(40%+150px)] md:left-[calc(40%+150px)]"
          />
        </div>
        <div
          className="pointer-events-none absolute top-[13%] left-[16%] w-[100%] -rotate-2 overflow-hidden rounded-xl border border-white/10 bg-[#0f1729] shadow-[0_30px_80px_rgba(0,0,0,.6),0_0_0_1px_rgba(253,193,26,.06)]"
          aria-hidden
        >
          <img
            src="/marketing/requests-full.webp"
            alt=""
            width={1920}
            height={1200}
            className="block w-full"
          />
        </div>
        <Link href={rootPath()} className="relative z-10 flex items-center">
          <AppWordmark className="h-6 w-auto" />
        </Link>
        <div className="relative z-10 max-w-sm space-y-3">
          <p className="text-primary font-mono text-[11px] tracking-[0.2em] uppercase">
            Built by Rebulk
          </p>
          <h2 className="text-3xl font-black tracking-tight text-balance">
            {HERO_HEADLINE_LEAD}
            <span className="text-primary">{HERO_HEADLINE_ACCENT}</span>
          </h2>
          <p className="text-sm text-balance text-white/70">{HERO_SUBHEAD}</p>
        </div>
      </div>
      <div className="flex flex-col items-center justify-center gap-6 p-6 md:p-10">
        <div className="w-full max-w-sm">
          <Link
            href={rootPath()}
            className="mb-8 flex items-center justify-center gap-2 lg:hidden"
          >
            <AppWordmark className="h-5 w-auto text-black dark:text-white" />
          </Link>
          <div className="mb-6 flex flex-col gap-2 text-center">
            <h1 className="text-xl font-semibold">{title}</h1>
            <p className="text-muted-foreground text-sm text-balance">
              {description}
            </p>
          </div>
          {children}
        </div>
      </div>
    </div>
  )
}
