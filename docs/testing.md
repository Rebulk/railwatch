# Testing with Railwatch

Railwatch already watches every query, N+1, span, exception, and outgoing
request your app makes. The same instrumentation works in your test suite,
which means a spec can assert on them. CI can fail a pull request that
adds an N+1 or doubles a page's query count.

## Set-up

RSpec: add one line to `spec/rails_helper.rb`. The install generator adds it
for you.

```ruby
require "rspec/rails"
require "railwatch/rspec"
```

That requires `railwatch/spec_helper`, includes `Railwatch::SpecHelper` into every
example group, and defines the matchers below.

Minitest: the same thing in `test/test_helper.rb`. The require includes
`Railwatch::Minitest` into `ActiveSupport::TestCase` on its own.

```ruby
require "rails/test_help"
require "railwatch/minitest"
```

Railwatch must be *enabled* in the test environment or every block would look
empty. An embedded install (`transport = :local`) is enabled with no token. A
cloud install needs a token present, so set any non-blank `RAILWATCH_TOKEN` for
the test env. Either way records go to an in-memory transport, never over the
network or into the telemetry database. If Railwatch is disabled, the matchers
raise `Railwatch::SpecHelper::Disabled` rather than quietly passing.

An embedded install adds its two databases to the `test` environment too, and
Rails' schema check refuses to run the suite while their migrations are
pending. `bin/rails db:test:prepare` does not create them, because they keep no
schema file; run this once locally and as a CI setup step:

```sh
RAILS_ENV=test bin/rails db:prepare
```

Sampling is forced on for the block, so a fractional `c.sample` in the app's
test config can't turn an assertion into one that never fires either.

## Matchers

All of them are block matchers.

### `have_railwatch_queries`

```ruby
expect { OrderSummary.new(order).to_h }.to have_railwatch_queries(at_most: 5)
expect { user.reload }.to have_railwatch_queries(exactly: 1)
expect { Report.generate }.to have_railwatch_queries(at_least: 1)
```

Pass exactly one of `at_most:`, `exactly:`, `at_least:`. Passing two, or
none, raises `ArgumentError`. On failure the message lists every statement,
each truncated to 120 characters, so CI output says what to go and fix:

```
expected the block to run at most 1 database queries, but it ran 3:
  1. SELECT COUNT(*) FROM "widgets"
  2. SELECT "widgets".* FROM "widgets" WHERE "widgets"."id" = ?
  3. SELECT "gadgets".* FROM "gadgets" WHERE "gadgets"."id" = ?
```

Cached queries don't count. They never become `query` records.

### `have_railwatch_n_plus_one`

```ruby
expect { get "/widgets" }.not_to have_railwatch_n_plus_one
```

Matches when the block trips Railwatch's own N+1 detector: the same normalized
query shape repeated `config.n_plus_one_threshold` times (default 5) inside one
execution. The negated failure message names the shape, the repeat count, and
the app-code line that issued it.

### `record_railwatch_span`

```ruby
expect { Checkout.new(cart).total }.to record_railwatch_span("checkout.total")
expect { Checkout.new(cart).total }.to record_railwatch_span(nil) # any span
```

### `record_railwatch_exception` / `record_railwatch_exceptions`

```ruby
expect { importer.run }.to record_railwatch_exception(ArgumentError)
expect { importer.run }.not_to record_railwatch_exceptions
```

These see anything that reaches `Rails.error`: `Rails.error.handle`,
`Rails.error.report`, `Railwatch.report`, and unhandled exceptions a request
spec's middleware catches. A block that raises out of the matcher still
raises; nothing is swallowed.

### `have_railwatch_outgoing_requests`

```ruby
expect { SyncCustomers.run }.to have_railwatch_outgoing_requests(at_most: 1)
```

Same bounds as `have_railwatch_queries`. Failures list the method and URL of
every request the block made.

## Minitest assertions

```ruby
assert_railwatch_queries(at_most: 5) { OrderSummary.new(order).to_h }
refute_railwatch_n_plus_one { get widgets_url }
assert_railwatch_span("checkout.total") { Checkout.new(cart).total }
```

`assert_railwatch_queries` takes `exactly:`/`at_most:`/`at_least:` too, and
produces the same statement listing on failure.

## Where the matchers work

Anywhere. A request spec's `get "/widgets"` opens and closes its own
execution. So its whole tree is visible by the time the block returns:
queries, N+1s, outgoing HTTP.

```ruby
expect { get "/widgets" }.to have_railwatch_queries(at_most: 6)
```

A model or service spec has nothing executing, so the block is wrapped in an
execution for the duration of the assertion and closed afterwards. No parent
`command` record is written for it. A block running *inside* an execution you
opened yourself has its records read straight off that execution's buffer.

Under the hood every matcher calls `Railwatch::SpecHelper#railwatch_capture`,
which is public. Use it directly for anything the matchers don't cover:

```ruby
records = railwatch_capture { get "/widgets" }
expect(records.select { |r| r[:t] == "cache_event" }.size).to eq(2)
```

`railwatch_records(type = nil)` is still there for assertions about the whole
example rather than one block.

## CI performance gate

Put the budget for a hot path in a spec and let it fail the build when
someone regresses it. The point is that the number is checked in, so raising
it is a reviewed decision rather than an accident:

```ruby
# spec/performance/widgets_spec.rb
RSpec.describe "performance budgets", type: :request do
  before { create_list(:widget, 25) }

  it "renders the widget index within its query budget" do
    expect { get "/widgets" }.to have_railwatch_queries(at_most: 6)
  end

  it "renders the widget index without an N+1" do
    expect { get "/widgets" }.not_to have_railwatch_n_plus_one
  end

  it "renders the widget index without calling out to anyone" do
    expect { get "/widgets" }.to have_railwatch_outgoing_requests(exactly: 0)
  end
end
```

Two ways to run it. Tag these examples and run them as their own CI step
with `bundle exec rspec --tag performance`, so a budget failure is obvious in
the job list. Or leave them in the main suite so any pull request that adds a
query fails immediately. Either way the failure message names the statements,
so the fix is usually an `includes` one line away.

Seed enough rows in `before` that an N+1 actually crosses
`config.n_plus_one_threshold`. With three records, a five-query threshold
never fires and the gate passes on code that would melt in production.
