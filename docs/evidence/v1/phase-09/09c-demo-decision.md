# 09c: the decision on `demo/` (finding T10)

`open-findings.md` T10 classed core `demo/` as POST-V1 and left the decision to
this unit: "09c decides whether to remove after the sample lands".

## The decision

**`demo/` is left exactly as it is in V1.** Not one byte of it was touched.

```
$ git ls-files demo
demo/config/config.exs
demo/lib/demo.ex
demo/lib/demo/application.ex
demo/lib/demo/plans.ex
demo/lib/demo/repo.ex
demo/mix.exs
demo/mix.lock
demo/priv/repo/migrations/20260711000001_add_aurora_meter.exs
```

Eight tracked files, unchanged, `mix.lock` and the migration still pinned to
July 2026.

## Why

It costs nothing to ship, because it is not shipped. `mix.exs`'s
`package[:files]` is an explicit allow list and `demo` is not in it;
`09c-packaging.md` asserts that, with a control, and
`test/aurora_meter/packaging_test.exs` now holds it in the library's own suite.

It costs nothing to maintain, because nothing depends on it. It is not in CI, it
is not in `docs[:extras]`, and no test references it.

Deleting it is a change to a tracked tree in a repository that is about to be
tagged, and it buys V1 nothing. Updating it would mean maintaining two examples
of the same thing, which is worse than having one stale one that says it is
stale.

## How it is now described

The sample's `README.md`, first section, under "What this is and what it is not":

> **It is not the library's only example.** `demo/` in the package root is a
> historical minimal wiring example pinned to a July 2026 migration, kept for
> reference and excluded from the published archive. This directory is the
> current one.

The package `README.md` now points at the sample from above the quick start, so
a reader arriving from hexdocs meets the runnable one first.

## `open-findings.md` T10

The row already carries this decision, written by the orchestrator when the
build document was prepared:

> CLOSED by 09c: left in place and described as historical. It is excluded from
> the Hex archive by `package.files`, so it costs nothing to ship, and removing
> a tracked directory during V1 adds churn to a repository that is about to be
> tagged.

This unit agrees with it, has now made the description in the README true rather
than planned, and changed nothing in `open-findings.md`. Removal remains a
post-V1 item and needs no further decision from this phase.

## One thing a post-V1 agent should know

`demo/priv/repo/migrations/20260711000001_add_aurora_meter.exs` calls
`AuroraMeter.Migration.up/1` with July's arguments. The installer now emits a
**bounded** body (`up(from: 1, version: 10, concurrently: false)`), which is
09b's change. If anybody ever revives `demo/`, that migration is the first thing
to regenerate, and the second is its `mix.lock`, which predates every schema
version from 2 onwards.
