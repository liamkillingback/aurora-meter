# 03b: the API as shipped

Everything build unit 03b added to the public surface, in the shape the code
carries. `docs/api.md` is the published form of this and
`test/aurora_meter/api_inventory_test.exs` checks both against the code on
every `mix test`.

## Facade

```elixir
@spec AuroraMeter.record(term(), atom(), pos_integer(), keyword()) ::
        {:ok, AuroraMeter.Event.t(), :inserted | :duplicate}
        | {:error, {:invalid, [{atom(), atom()}]}}
        | {:error, {:conflict, AuroraMeter.Event.t()}}
        | {:error, {:unavailable, term()}}
        | {:error, {:unsupported, :durable_events}}

@spec AuroraMeter.record_batch([map()], keyword()) ::
        {:ok, [{AuroraMeter.Event.t(), :inserted | :duplicate}]}
        | {:error, {:invalid, [{non_neg_integer(), atom(), atom()}]}}
        | {:error, {:conflict, non_neg_integer(), AuroraMeter.Event.t()}}
        | {:error, {:unavailable, term()}}
        | {:error, {:unsupported, :durable_events}}
```

`record/4` options: `:id` (required), `:occurred_at` (required),
`:dimensions`, `:metadata`, `:future_tolerance`, `:timeout`. A batch element is
`%{tenant:, feature:, quantity:, id:, occurred_at:}` plus the optional keys.

## `AuroraMeter.Events`

```elixir
@spec get(term(), String.t()) :: {:ok, Event.t()} | {:error, :not_found | error()}
@spec total(term(), atom(), DateTime.t()) :: non_neg_integer()
@spec count(term(), atom(), DateTime.t()) :: %{quantity: non_neg_integer(), events: non_neg_integer()}
@spec stream(keyword()) :: Enumerable.t()
@spec after_commit([Event.t()] | Event.t()) :: :ok
```

`stream/1` options: `:after_seq` (default `0`), `:limit` (default `1000`),
`:tenant`, `:feature`, `:from`, `:to`.

`count/3` is additive to the build document's list. `total/3` answers the
quantity and nothing else, and a reader that needs the number of events behind
it (a reconciliation, a dashboard) would otherwise have to stream the events to
count them.

## Validation errors

Every `{:invalid, errors}` entry is `{field, reason}`, or `{index, field,
reason}` in a batch. The full vocabulary as shipped:

| Field | Reasons |
|---|---|
| `:tenant` | `:empty` |
| `:feature` | `:missing`, `:undeclared` |
| `:quantity` | `:not_a_positive_integer`, `:out_of_range` |
| `:id` | `:missing`, `:not_a_binary`, `:empty`, `:not_utf8`, `:too_long`, `:reserved_prefix`, `:duplicate_id_in_batch` |
| `:occurred_at` | `:missing`, `:not_a_datetime`, `:not_utc`, `:future` |
| `:dimensions` | `:not_a_map`, `:non_string_key`, `:too_many_keys`, `:key_too_long`, `:value_too_long`, `:non_scalar_value`, `:not_json_safe` |
| `:metadata` | `:not_a_map`, `:non_string_key`, `:not_json_encodable`, `:too_large` |
| `:batch` | `:too_many_events`, `:too_large` |

`{:unavailable, reason}` reasons as shipped: `:overloaded`,
`:gate_unavailable`, `:timeout`, `:pool_timeout`, `:conflict_unresolved`,
`{:outbox, reason}`, `{:constraint, name}`, `{:postgres, code}`.

Limits: id 1 to 128 bytes of UTF-8; dimensions at most 32 keys, key at most 64
bytes, scalar value at most 256 bytes; metadata at most 16 KiB of JSON text;
batch at most 500 elements and 1 MiB of encoded dimensions plus metadata.
Every size is `byte_size/1` of the bytes the caller sent, never a stored size
(`open-findings.md` X104).

## `AuroraMeter.Storage`: seven new callbacks and a capability declaration

```elixir
@callback capabilities() :: [capability()]
@callback record_events([event_entry()], keyword()) ::
            {:ok, [record_outcome()]}
            | {:error, {:conflict, non_neg_integer(), Event.t()}}
            | {:error, term()}
@callback load_event(String.t(), String.t()) ::
            {:ok, Event.t()} | {:error, :not_found | {:unsupported, capability()}}
@callback load_event_total(String.t(), atom() | String.t(), DateTime.t()) ::
            {:ok, %{quantity: non_neg_integer(), events: non_neg_integer()}}
            | {:error, {:unsupported, capability()}}
@callback stream_events(non_neg_integer(), keyword()) ::
            {:ok, [Event.t()]} | {:error, {:unsupported, capability()}}
@callback write_projection_totals(non_neg_integer(), [projection_total()]) :: :ok | {:error, term()}
@callback activate_projection(non_neg_integer()) :: :ok | {:error, term()}
```

`capability()` is `:durable_events | :corrections | :projection_generations |
:event_streaming`. New public types: `capability/0`, `event_entry/0`,
`record_outcome/0`, `projection_total/0`. New dispatchers: all seven plus
`AuroraMeter.Storage.supports?/1`.

Deviations from the build document's shapes, and why:

- `load_event/2` returns `{:ok, event} | {:error, :not_found}` rather than
  `event | nil`, so the unsupported case has somewhere to go and
  `AuroraMeter.Events.get/2` can return it unchanged.
- `load_event_total/3` returns `{:ok, %{quantity:, events:}}` rather than an
  integer, for the same reason and because the projection carries two numbers.
- `stream_events/2` takes `(cursor, opts)` with the cursor a `seq`, matching
  `architecture-map.md` 4.3's `(cursor, limit)` while carrying the filters the
  build document specifies.

## The outbox seam

```elixir
@callback AuroraMeter.Events.Outbox.enqueue([item()], context()) :: :ok | {:error, term()}
```

`item()` is `%{event: Event.t(), eligibility: :eligible | {:ineligible, reason}}`
with `reason` one of `:feature_buffered` or `:attribution_unresolved`.
`context()` is `%{repo: module(), timeout: timeout()}`. Shipped implementation:
`AuroraMeter.Events.Outbox.Noop`.

`:timeout` in the context is additive to the build document, which specified
`%{repo: repo}`. An implementation that issues a statement inside the record
transaction needs the same bound the adapter applies to its own, or the
`record_timeout` promise is only as strong as the slowest thing Pro does.

## Configuration

| Key | Type | Default |
|---|---|---|
| `:feature_sources` | `%{atom => :buffered \| :events}` | `%{}` |
| `:events_outbox` | module or `nil` | `nil` |
| `:events_future_tolerance` | seconds | `300` |
| `:record_timeout` | milliseconds | `15_000` |
| `:record_max_concurrency` | positive integer | `64` |

Accessors: `Config.feature_sources/0`, `Config.feature_source/1`,
`Config.events_outbox/0`, `Config.events_future_tolerance/0`,
`Config.record_timeout/0`, `Config.record_max_concurrency/0`.

`:feature_sources` is 03c's key by `api-change-map.md` 1.5. It lands here
because the record path needs the accessor to compute export eligibility and
cold seeding needs it to choose a source; 03c still owns the `track/4` guard,
the `durable_features` interaction and the boot error.

## Telemetry

One **span**, `[:aurora_meter, :record]`, emitted with `:telemetry.span/3` and
producing `:start`, `:stop` and `:exception`. `:stop` measurements `duration`
and `count`; metadata `result`, `kind`, `feature`, `batch_size`, `tenant_key`,
`durability`, `projection`.

A span and not the flat `[:aurora_meter, :record]` event the build document
described: `api-change-map.md` 1.6 is binding and specifies the span triple,
with the reason (an OpenTelemetry bridge must open the span before the database
work starts so Ecto's spans nest inside it). The conflict is recorded in the
03b report.

## PubSub

`{:aurora_meter, :event, %{tenant_key, feature, event_id, quantity,
period_start, kind}}` on `AuroraMeter.Broadcaster.topic/1`, after commit, one
per inserted event and none per duplicate.

## Test helpers

`AuroraMeter.StorageCase` (`use ... , adapter:, checkout:, tenant_prefix:`),
plus `StorageCase.entry/3` and `StorageCase.active_generation/0`.

## Internal, and deliberately not public

`AuroraMeter.Events.Canonical`, `AuroraMeter.Events.Gate` and
`AuroraMeter.Counter.apply_projection/2`, per `api-change-map.md` 1.8 and
section 5. `AuroraMeter.Storage.Ecto.host_transaction?/0` is public on an
internal module.

## Removed

`AuroraMeter.Counter.restore_pending/2` (open finding C8: unreachable from
`lib/` since 0.4.0). `Counter` is an internal module, so this is not a breaking
change to the supported surface. Core's `CHANGELOG.md` carries no `Unreleased`
section by design (`release_metadata_test.exs` G02 refuses a non-empty one), so
the line belongs to the release unit that cuts 1.0.
