import { Head, usePage } from "@inertiajs/react"

import { AiAssistant } from "@/components/marketing/ai-assistant"
import { FeatureGrid } from "@/components/marketing/feature-grid"
import { MarketingFooter } from "@/components/marketing/footer"
import { MarketingHero } from "@/components/marketing/hero"
import { HeroStageProvider } from "@/components/marketing/hero-line"
import { InstallSnippet } from "@/components/marketing/install-snippet"
import { MarketingNav } from "@/components/marketing/nav"
import { ProductPreview } from "@/components/marketing/product-preview"
import { Reveal } from "@/components/marketing/reveal"

export default function Welcome() {
  const { auth } = usePage().props
  const signedIn = Boolean(auth.user)

  return (
    <>
      <Head title="Railwatch — monitoring for Rails apps" />
      {/* The marketing page is a brand page, so it always renders in the navy
          stack regardless of the signed-in appearance setting. */}
      <div className="dark bg-background text-foreground min-h-screen">
        <Reveal step={0}>
          <MarketingNav signedIn={signedIn} />
        </Reveal>
        <HeroStageProvider>
          <Reveal step={1}>
            <MarketingHero signedIn={signedIn} />
          </Reveal>
          <Reveal step={2}>
            <ProductPreview />
          </Reveal>
        </HeroStageProvider>
        <Reveal step={3}>
          <FeatureGrid />
        </Reveal>
        <Reveal step={4}>
          <AiAssistant />
        </Reveal>
        <Reveal step={4}>
          <InstallSnippet />
        </Reveal>
        <Reveal step={5}>
          <MarketingFooter />
        </Reveal>
      </div>
    </>
  )
}
