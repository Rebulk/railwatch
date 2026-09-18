import { Link } from "@inertiajs/react"

import { Button } from "@/components/ui/button"
import { docsPath, signUpPath } from "@/routes"

import { HERO_HEADLINE_ACCENT, HERO_HEADLINE_LEAD, HERO_SUBHEAD } from "./copy"
import { HeroLoop } from "./hero-line"
import { RebulkWordmark } from "./rebulk-wordmark"

export function MarketingHero({ signedIn }: { signedIn: boolean }) {
  return (
    <HeroLoop>
      <section className="relative mx-auto max-w-3xl px-6 pt-14 pb-0 text-center">
        <p className="text-primary mb-5 flex items-baseline justify-center gap-3 font-mono text-[11px] tracking-[0.2em] uppercase">
          Built by
          <a
            href="https://rebulk.com"
            className="text-foreground hover:text-primary transition-colors"
          >
            <RebulkWordmark className="h-2.5 w-auto" />
          </a>
        </p>
        <h1 className="text-5xl font-black tracking-tight text-balance sm:text-6xl">
          {HERO_HEADLINE_LEAD}
          <span className="text-primary">{HERO_HEADLINE_ACCENT}</span>
        </h1>
        <p className="text-muted-foreground mx-auto mt-5 max-w-xl text-lg text-balance">
          {HERO_SUBHEAD}
        </p>
        <div className="mt-8 flex items-center justify-center gap-3">
          {signedIn ? (
            <Button asChild size="lg">
              <Link href="/dashboard">Open dashboard</Link>
            </Button>
          ) : (
            <Button asChild size="lg">
              <Link href={signUpPath()}>Get started</Link>
            </Button>
          )}
          <Button asChild variant="outline" size="lg">
            <Link href={docsPath()}>Read the docs</Link>
          </Button>
        </div>
        {/* Reserves the height the lower run and signal need; the product
            preview overlaps its bottom edge so track and product share the
            screen on a phone. */}
        <div className="mt-6 h-32" data-hero-strip />
      </section>
    </HeroLoop>
  )
}
