import AppLogoIcon from "./app-logo-icon"
import AppWordmark from "./app-wordmark"

// The wordmark when there is room; the R tile once the sidebar collapses to icons.
export default function AppLogo() {
  return (
    <>
      <div className="hidden aspect-square size-8 shrink-0 items-center justify-center rounded-md bg-[#0F1729] text-white group-data-[collapsible=icon]:flex">
        <AppLogoIcon className="size-6" />
      </div>
      <AppWordmark className="h-4 w-auto group-data-[collapsible=icon]:hidden" />
    </>
  )
}
