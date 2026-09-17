# Contributing

Issues and pull requests are welcome. This page is what you need to get the
suite running and what a change is expected to come with.

`aurora_meter_pro` is a separate commercial package and takes no external
contributions. Everything here is about this repository.

## Getting a test database

Tests need a local PostgreSQL. `mix test.setup` creates the test database and
migrates it through every schema version.

```sh
mix deps.get
mix test.setup
mix test
```

`DB_PORT` selects the port when yours is not 5432. Nothing else is configurable
from the environment for a normal run.

## What `mix check` runs

```sh
mix check
```

in order: `mix format --check-formatted`, `mix compile --warnings-as-errors
--force`, `mix credo --strict`, `mix dialyzer`, `mix test`, and `mix docs
--warnings-as-errors`. A pull request is expected to leave all six green.

Two notes on that list, both of which are there because of something that went
wrong once:

- `mix docs` is run with `--warnings-as-errors` and an explicit `--output`,
  because a bare `mix docs` exits 0 on a broken reference and writes generated
  HTML into the package tree;
- the compile step is `--force`, so a warning that was already compiled away
  still fails.

`mix coverage` runs the suite with coverage and a measured floor. It is a
separate step and it is not part of `mix check`, because a coverage threshold
failing on a minimum-runtime build would be a tooling problem reported as a test
failure.

## Naming a test after the invariant it proves

Correctness tests carry the invariant id in their description:

```elixir
test "I06 a retry with the same id and payload is a duplicate with no second effect" do
```

`docs/correctness.md` indexes them, and
`test/aurora_meter/correctness_index_test.exs` fails when the index names a test
that does not exist or an invariant that names no test. If you add a test for an
existing invariant, add its exact description to that page too.

The suite parses test sources rather than grepping them, so a test named only in
a comment or a doc string does not count as existing. That is deliberate.

## A change that touches money or quotas needs a concurrency test

Ledger and quota defects do not show up in a sequential test. If your change
touches `AuroraMeter.Credits`, `AuroraMeter.Counter` or the entitlement path,
add a test that exercises it from **independent database connections**, not from
tasks sharing the sandbox's. `AuroraMeter.CreditsConcurrencyTest` and
`AuroraMeter.RecordConcurrencyTest` are the patterns to copy, and
`docs/testing.md` explains why a shared connection cannot see the defect.

## What the documentation checks enforce

Several suites read the documentation and will fail a pull request that leaves
it behind:

- `AuroraMeter.HouseStyleTest`: no em dash and no en dash in `README.md`,
  `NOTICE.md`, the unreleased part of `CHANGELOG.md`, the guides under `docs/`,
  or the doc strings and rendered strings under `lib/`. Use a comma, a colon,
  parentheses or a full stop. A dash inside a code sample or a URL is not
  reported.
- `AuroraMeter.DocsClaimsTest`: no document and no doc string claims a bounded
  loss window, exactly-once delivery or a global quota, and every "Proven by"
  cell of `docs/guarantees.md` names a test that exists.
- `AuroraMeter.ApiInventoryTest`: every entry in `docs/api.md` exists, carries a
  `@spec`, and prints the return type that `@spec` declares. A module with an
  `iex>` example must be named by a `doctest` declaration somewhere.
- `AuroraMeter.Bench.ClaimsTest`: a published throughput figure must come from
  the measurement artifact under `docs/evidence/`, and a superseded figure may
  not reappear anywhere.

Each of those has a fixture or a negative control beside it, so if you think one
is wrong, look at the control first: it is there to show you what the check can
and cannot see.

## Decision records

A decision that constrains later work goes in `docs/adr/NNNN-title.md` with a
`# ADR NNNN: Title` heading and a `Status:` line.
`test/aurora_meter/adr_format_test.exs` enforces the shape, and
`test/aurora_meter/release_metadata_test.exs` enforces that an ADR describing
shipped behaviour is published in `mix.exs` docs extras while one describing
unshipped design is not.

## Licence

This project is MIT (see [LICENSE](LICENSE)). By opening a pull request you
agree that your contribution is licensed under those terms. There is no CLA.

## What is not accepted

- A change that adds an outbound network request to the free core. It makes
  none, that is a documented property, and `SECURITY.md` says so.
- A reference from core to a module in `aurora_meter_pro`. The boundary is in
  `docs/architecture.md` section 5 and is one direction only.
- A new required callback on a public behaviour outside a major release. Adding
  one breaks every host adapter, and `docs/support-policy.md` section 1 says it
  is a major change.
- Deleting a saved regression seed under `test/regressions/seeds/` to make the
  suite green.
