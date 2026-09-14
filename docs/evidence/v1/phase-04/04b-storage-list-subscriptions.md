# 04b, core's half: `AuroraMeter.Storage.list_subscriptions/2`

Build unit 04b touches core for one reason. Aurora Meter Pro's usage reporter
queried `AuroraMeter.Schema.Subscription` directly, which
`free-pro-boundary.md` rule 1 forbids, and the replacement it names is a keyset
listing on `AuroraMeter.Storage`. `dependency-map.md` lists 04b's repository as
"Pro" only; the two statements cannot both be satisfied, and this document
follows `free-pro-boundary.md`.

## The callback

```elixir
@callback list_subscriptions(cursor :: String.t() | nil, opts :: keyword()) ::
            {[Subscription.t()], next_cursor :: String.t() | nil}
```

Dispatcher: `AuroraMeter.Storage.list_subscriptions/2`, with both arguments
defaulted. Options: `:limit` (default 100) and `:status_in` (a list of status
strings; omitted means every status).

`cursor` is the `tenant_key` the previous page ended on, or `nil` for the first
page; the page returned is strictly after it. `next_cursor` is `nil` exactly
when the page came back shorter than `limit`, which is the only honest end
signal: a page that is exactly full may or may not be the last one, so the
caller is asked once more rather than guessing.

**Keyset, not offset**, and the reason is not performance. The caller is a
worker that walks every subscription while other processes insert and delete
them; an offset page silently skips a row when an earlier one is removed under
it, and a skipped subscription is usage nobody bills.

## The implementation

`AuroraMeter.Storage.Ecto.list_subscriptions/2`. The keyset is on `tenant_key`,
which carries the table's unique index, so the scan is index-backed and a page
cannot repeat or skip a row.

## The conformance cases added to `AuroraMeter.StorageCase`

`AuroraMeter.StorageCase` previously asserted nothing about subscriptions, on
the grounds that those callbacks predated it. This one does not predate it, and
the two ways a keyset goes wrong are both silent and both cost money, so it is
asserted:

- `list_subscriptions/2 pages by keyset without repeating or skipping a row`.
  It pages **one row at a time**, which is the setting that exposes both
  defects: an inclusive cursor repeats its own last row for ever, and a cursor
  built from anything but the sort key skips rows. Neither shows up at a page
  size larger than the data. It then pages the same data in bulk and asserts the
  two walks return the same set, and it bounds the walk at 1,000 iterations so a
  cursor that never terminates fails here rather than hanging the suite.
- `list_subscriptions/2 honours status_in and ends its cursor`.

Both run against the shipped Ecto adapter (`AuroraMeter.StorageCaseEctoTest`,
non-sandbox connections) and against `AuroraMeter.Test.IncapableStorage`, which
declares no durable capability and delegates these two.

## Other callers updated

`list_subscriptions/2` is a **required** callback, so every implementation in
both repositories gained it: the two storage fakes, the two inline stubs in
`AuroraMeter.ClusterTest`, and both fault storages (core's and Pro's), where it
is instrumented at `:before_commit` and `:after_commit_before_ack` like every
other operation, so the harness parity guard still passes.

## Gate

`mix check` in core, at the commit this unit produced:

| Step | Result |
|---|---|
| `mix format --check-formatted` | pass |
| `mix compile --warnings-as-errors --force` | pass |
| `mix credo --strict` | pass, 2,206 mods/funs, no issues |
| `mix dialyzer` | pass, `Total errors: 0, Skipped: 0, Unnecessary Skips: 0` |
| `mix test` | **1200 of 1201**, 3 excluded |
| `mix docs --warnings-as-errors` | pass |

The one failure is `AuroraMeter.ReleaseMetadataTest` / `test G02 one version,
five places G02 nothing is left in an Unreleased section above the release
heading`, and it is **not caused by 04b**. It was reproduced with 04b's
changelog entry and with `git show HEAD:CHANGELOG.md` in its place: the same
single failure both ways, 11/12 passed. The test was added in `477a7a6`, which
cut core 0.5.0 and emptied the section, and the section was repopulated by
`b93afc5` (04a). See `pro:docs/evidence/v1/phase-04/04b-outbox.md`, "Core's
gate", for the conflict and why it is reported rather than fixed here.

**X135 again.** Core's suite rewrote `docs/evidence/v1/phase-03/03d-activation-atomicity.txt`
during this run, as it did for 04a. It was restored with
`git checkout -- docs/evidence/v1/phase-03/` and the tree is byte identical.
