# 03c: the `with_quota/4` outcome matrix

Measured by `AuroraMeter.FeatureSourceEvidenceTest`, which asserts every
number below before writing this file. Generated 2026-09-14T19:31:46.196160Z.

Each cell is a fresh tenant. The callback reserves **5**, and on the normal
ending an `:events`-source callback also records **5**, so the only
difference between the two halves of the table is the settle rule rather than
the arithmetic.

`value`, `pending_flush` and `reserved` are the ETS row read immediately
after the call and **before** the flush-batch snapshot, which is the reading
that shows what the call itself left behind: the snapshot is what takes
`pending_flush` away. `flush entries` counts what that snapshot then held for
that tenant.
`counter row` is `AuroraMeter.Storage.load_counter/3` after a flush, which is
the exact read `AuroraMeter.Pro.UsageReporter.report_one/5` makes and
therefore the only number that can become a charge. `durable total` is
`AuroraMeter.Events.total/3`.

| source | callback ends | value | pending_flush | reserved | flush entries | counter row | durable total |
|---|---|---|---|---|---|---|---|
| `buffered` | normal | 5 | 5 | 0 | 1 | 5 | 0 |
| `buffered` | raise | 0 | 0 | 0 | 0 | nil | 0 |
| `buffered` | throw | 0 | 0 | 0 | 0 | nil | 0 |
| `buffered` | exit | 0 | 0 | 0 | 0 | nil | 0 |
| `events` | normal | 5 | 0 | 0 | 0 | nil | 5 |
| `events` | raise | 0 | 0 | 0 | 0 | nil | 0 |
| `events` | throw | 0 | 0 | 0 | 0 | nil | 0 |
| `events` | exit | 0 | 0 | 0 | 0 | nil | 0 |

## What the table says

**The buffered half is unchanged**, and is here as the control: a normal
return commits the reservation, so `value` stays at 5, the delta reaches the
flush batch and `aurora_meter_counters` holds 5 afterwards. A raise, a throw
and an exit each release it, and nothing is persisted.

**The events half never writes a counter row at all.** On every ending,
including the successful one, the reservation is released: `pending_flush` is
never written, the flush batch is empty for that tenant and `load_counter/3`
is `nil`. `value` does not simply return to zero on the successful row, and
that is the point rather than an exception: the estimate came back
(`+5`, `-5`) and the projection of the recorded event stayed (`+5`), so the
in-memory value settles on the durable total. On the three failing rows
nothing was recorded, so both are zero.

That last line is the whole of I08 on this path. A reservation over an
events-source feature is admission control; the charge is the event.
