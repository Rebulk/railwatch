import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"

interface Shortcut {
  keys: string[]
  description: string
}

const GROUPS: { title: string; shortcuts: Shortcut[] }[] = [
  {
    title: "Navigation",
    shortcuts: [
      { keys: ["⌘", "K"], description: "Open command palette" },
      { keys: ["g", "d"], description: "Go to dashboard" },
      { keys: ["g", "o"], description: "Go to Overview" },
      { keys: ["g", "r"], description: "Go to Requests" },
      { keys: ["g", "j"], description: "Go to Jobs" },
      { keys: ["g", "q"], description: "Go to Queries" },
      { keys: ["g", "i"], description: "Go to Issues" },
      { keys: ["?"], description: "Show this help" },
    ],
  },
  {
    title: "Lists (requests, jobs, queries, issues, logs, …)",
    shortcuts: [
      { keys: ["j"], description: "Move highlight down" },
      { keys: ["k"], description: "Move highlight up" },
      { keys: ["↵"], description: "Open highlighted row" },
      { keys: ["o"], description: "Open highlighted row in a new tab" },
      { keys: ["Esc"], description: "Clear highlight" },
      { keys: ["/"], description: "Focus the filter bar" },
    ],
  },
]

export function ShortcutsDialog({
  open,
  onOpenChange,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
}) {
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-sm">
        <DialogHeader>
          <DialogTitle>Keyboard shortcuts</DialogTitle>
          <DialogDescription>Available anywhere in the app.</DialogDescription>
        </DialogHeader>
        <div className="flex flex-col gap-4">
          {GROUPS.map((group) => (
            <div key={group.title} className="flex flex-col gap-2">
              <div className="text-muted-foreground text-xs font-medium tracking-wide uppercase">
                {group.title}
              </div>
              <ul className="flex flex-col gap-2">
                {group.shortcuts.map((shortcut) => (
                  <li
                    key={shortcut.description}
                    className="flex items-center justify-between text-sm"
                  >
                    <span className="text-muted-foreground">
                      {shortcut.description}
                    </span>
                    <span className="flex items-center gap-1">
                      {shortcut.keys.map((key, i) => (
                        <kbd
                          key={i}
                          className="bg-muted rounded border px-1.5 py-0.5 font-mono text-xs"
                        >
                          {key}
                        </kbd>
                      ))}
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      </DialogContent>
    </Dialog>
  )
}
