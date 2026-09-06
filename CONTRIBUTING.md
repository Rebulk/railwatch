# Contributing

Install dependencies with `bundle install`, then run:

```sh
bundle exec rspec
bundle exec rubocop
bundle exec rake bench
```

Add or update specs with behavioral changes. Before opening a pull request,
add a concise entry under the current release in `CHANGELOG.md` and make sure
both benchmark gates pass.
