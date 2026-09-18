# Contributing

Install dependencies with `bundle install`, then run:

```sh
bundle exec rspec
bundle exec rubocop
bundle exec rake bench
```

The dashboard is a React app under `app/frontend`; the gem ships its build.
Working on it needs Node 22 and pnpm:

```sh
pnpm install
pnpm check && pnpm lint && pnpm format && pnpm test
bundle exec rake dashboard:build     # compiles into public/railwatch (gitignored)
```

`rake package:verify` and `rake package:build` run that build first, so a
release is `git tag vX.Y.Z && git push --tags`: the workflow builds the
bundle, verifies the package, and publishes. A host application never sees
Node; it installs the compiled bundle inside the gem.

### Releasing

1. `CHANGELOG.md` gets the entry, `lib/railwatch/version.rb` gets the
   version, both on `main`.
2. `git tag vX.Y.Z && git push --tags`.
3. `.github/workflows/release.yml` runs the specs, verifies the package,
   rebuilds the dashboard, refuses to publish a gem whose dashboard is
   missing (`rake package:assert_dashboard`), and pushes to RubyGems.

Publishing uses [RubyGems Trusted
Publishing](https://guides.rubygems.org/trusted-publishing/), so there is
no API key in this repository and none in GitHub secrets. It needs a
one-time setup on RubyGems that lives outside this repo, and without it
every tag fails at the last step with *"No trusted publisher configured
for this workflow"* while everything before it passes:

- On <https://rubygems.org/gems/railwatch>, under **Trusted publishers**,
  add a GitHub Actions publisher with repository `Rebulk/railwatch`,
  workflow `release.yml`, and no environment.
- A gem that has never been published uses a **pending** trusted
  publisher on the profile page instead, which the first release consumes.

The `publish` job needs `bundler-cache: true`, because it runs
`bundle exec rake` before it builds; without the bundle installed it fails
before reaching rake.

Add or update specs with behavioral changes. Before opening a pull request,
add a concise entry under the current release in `CHANGELOG.md` and make sure
both benchmark gates pass.
