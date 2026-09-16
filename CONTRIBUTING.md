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

Add or update specs with behavioral changes. Before opening a pull request,
add a concise entry under the current release in `CHANGELOG.md` and make sure
both benchmark gates pass.
