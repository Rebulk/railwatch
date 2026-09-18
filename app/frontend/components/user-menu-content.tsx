import { Link, router, usePage } from "@inertiajs/react"
import { Building2, Check, LogOut, Settings } from "lucide-react"

import {
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
} from "@/components/ui/dropdown-menu"
import { UserInfo } from "@/components/user-info"
import { useMobileNavigation } from "@/hooks/use-mobile-navigation"
import { sessionPath, settingsProfilePath, switchAccountPath } from "@/routes"
import type { SharedProps, User } from "@/types"

interface UserMenuContentProps {
  auth: {
    session: {
      id: string
    }
    user: User
  }
}

export function UserMenuContent({ auth }: UserMenuContentProps) {
  const { session, user } = auth
  const { account, accounts } = usePage<SharedProps>().props
  const cleanup = useMobileNavigation()

  const handleLogout = () => {
    cleanup()
    router.flushAll()
  }

  return (
    <>
      <DropdownMenuLabel className="p-0 font-normal">
        <div className="flex items-center gap-2 px-1 py-1.5 text-left text-sm">
          <UserInfo user={user} showEmail={true} />
        </div>
      </DropdownMenuLabel>
      <DropdownMenuSeparator />
      {accounts.length > 1 && (
        <>
          <DropdownMenuGroup>
            <DropdownMenuLabel className="text-muted-foreground text-xs">
              Accounts
            </DropdownMenuLabel>
            {accounts.map((a) => (
              <DropdownMenuItem
                key={a.id}
                onSelect={() => {
                  cleanup()
                  router.post(switchAccountPath(a.id))
                }}
              >
                <Building2 className="mr-2" />
                <span className="flex-1">{a.name}</span>
                {account?.id === a.id && <Check className="size-4" />}
              </DropdownMenuItem>
            ))}
          </DropdownMenuGroup>
          <DropdownMenuSeparator />
        </>
      )}
      <DropdownMenuGroup>
        <DropdownMenuItem asChild>
          <Link
            className="block w-full"
            href={settingsProfilePath()}
            as="button"
            prefetch
            onClick={cleanup}
          >
            <Settings className="mr-2" />
            Settings
          </Link>
        </DropdownMenuItem>
      </DropdownMenuGroup>
      <DropdownMenuSeparator />
      <DropdownMenuItem asChild>
        <Link
          className="block w-full"
          method="delete"
          href={sessionPath({ id: session.id })}
          as="button"
          onClick={handleLogout}
        >
          <LogOut className="mr-2" />
          Log out
        </Link>
      </DropdownMenuItem>
    </>
  )
}
