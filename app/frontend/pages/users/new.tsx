import { Form, Head, usePage } from "@inertiajs/react"

import { GoogleSignInButton } from "@/components/google-sign-in-button"
import InputError from "@/components/input-error"
import TextLink from "@/components/text-link"
import { Button } from "@/components/ui/button"
import { Checkbox } from "@/components/ui/checkbox"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Spinner } from "@/components/ui/spinner"
import AuthLayout from "@/layouts/auth-layout"
import { docPath, signInPath, signUpPath } from "@/routes"

interface Invitation {
  token: string
  email: string
  account: string
  inviter: string
}

export default function Register({ invitation }: { invitation?: Invitation }) {
  const { google_oauth: googleOauth } = usePage().props

  return (
    <AuthLayout
      title={invitation ? `Join ${invitation.account}` : "Create an account"}
      description={
        invitation
          ? `${invitation.inviter} invited you. Pick a name and password to get started.`
          : "Enter your details below to create your account"
      }
    >
      <Head title="Register" />
      <Form
        method="post"
        action={signUpPath()}
        resetOnSuccess={["password", "password_confirmation"]}
        disableWhileProcessing
        className="flex flex-col gap-6"
      >
        {({ processing, errors }) => (
          <>
            {invitation && (
              <input
                type="hidden"
                name="invitation_token"
                value={invitation.token}
              />
            )}
            <div className="grid gap-6">
              <div className="grid gap-2">
                <Label htmlFor="name">Name</Label>
                <Input
                  id="name"
                  type="text"
                  name="name"
                  required
                  autoFocus
                  tabIndex={1}
                  autoComplete="name"
                  disabled={processing}
                  placeholder="Full name"
                />
                <InputError messages={errors.name} className="mt-2" />
              </div>

              <div className="grid gap-2">
                <Label htmlFor="email">Email address</Label>
                <Input
                  id="email"
                  type="email"
                  name="email"
                  required
                  tabIndex={2}
                  autoComplete="email"
                  placeholder="email@example.com"
                  defaultValue={invitation?.email}
                  readOnly={Boolean(invitation)}
                />
                <InputError messages={errors.email} />
              </div>

              <div className="grid gap-2">
                <Label htmlFor="password">Password</Label>
                <Input
                  id="password"
                  type="password"
                  name="password"
                  required
                  tabIndex={3}
                  autoComplete="new-password"
                  placeholder="Password"
                />
                <InputError messages={errors.password} />
              </div>

              <div className="grid gap-2">
                <Label htmlFor="password_confirmation">Confirm password</Label>
                <Input
                  id="password_confirmation"
                  type="password"
                  name="password_confirmation"
                  required
                  tabIndex={4}
                  autoComplete="new-password"
                  placeholder="Confirm password"
                />
                <InputError messages={errors.password_confirmation} />
              </div>

              <div className="grid gap-2">
                <div className="flex items-start gap-3">
                  <Checkbox
                    id="terms"
                    name="terms"
                    required
                    tabIndex={5}
                    className="mt-0.5"
                  />
                  <Label
                    htmlFor="terms"
                    className="text-muted-foreground text-sm leading-snug font-normal"
                  >
                    I agree to the{" "}
                    <TextLink href={docPath("legal", "terms")} target="_blank">
                      Terms of Service
                    </TextLink>{" "}
                    and{" "}
                    <TextLink
                      href={docPath("legal", "privacy")}
                      target="_blank"
                    >
                      Privacy Policy
                    </TextLink>
                  </Label>
                </div>
                <InputError messages={errors.terms} />
              </div>

              <Button type="submit" className="mt-2 w-full" tabIndex={6}>
                {processing && <Spinner />}
                Create account
              </Button>
            </div>

            {googleOauth && (
              <>
                <GoogleSignInButton label="Continue with Google" />
                <p className="text-muted-foreground -mt-3 text-center text-xs">
                  Continuing with Google also accepts the Terms and Privacy
                  Policy.
                </p>
              </>
            )}

            <div className="text-muted-foreground text-center text-sm">
              Already have an account?{" "}
              <TextLink href={signInPath()} tabIndex={7}>
                Log in
              </TextLink>
            </div>
          </>
        )}
      </Form>
    </AuthLayout>
  )
}
