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

### Versioning

**A pull request does not bump the version.** Put the entry under
`## Unreleased` in `CHANGELOG.md` and leave `lib/railwatch/version.rb` and
`Gemfile.lock` alone.

Those two files are the only ones every branch touches identically, so a
branch that bumps conflicts with every other branch in flight, on both files,
every time -- and the lockfile conflict is the kind that resolves cleanly and
is still wrong. Deciding the number per-branch also cannot work: four open
pull requests cannot each know whether they are the patch release or the one
that lands after the feature, and whoever merges second has guessed wrong.

The release commit picks the number once, when the set of changes is known
and semver can actually be applied to it.

### Gemfile.lock

Commit it in the same commit as anything that changes resolution: a gemspec
dependency, a version bump. Bundler rewrites the lockfile in place before
running whatever you asked it to run, so your working copy is always correct
and the committed one is what breaks; CI installs frozen and fails the setup
step before a single test runs. `spec/railwatch/gemfile_lock_spec.rb` reads
the committed file for exactly this reason and will tell you first.

### Releasing

1. On `main`: retitle `## Unreleased` to `## X.Y.Z (YYYY-MM-DD)`, set
   `lib/railwatch/version.rb` to the same version, run `bundle lock`, and
   commit all three together. `spec/railwatch/gemfile_lock_spec.rb` fails if
   the lockfile is missing from that commit.
2. `git tag vX.Y.Z && git push --tags`. The tag must match what version.rb
   now says -- the workflow checks, because every other step reads the
   version from the file rather than the tag, and a mismatch would publish
   the wrong one under a tag claiming otherwise.
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
add a concise entry under `## Unreleased` in `CHANGELOG.md` and make sure both
benchmark gates pass.
