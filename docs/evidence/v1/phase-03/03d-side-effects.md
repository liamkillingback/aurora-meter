# 03d: the side-effect channels a replay is asserted silent on (I08)

A replay reads `aurora_meter_events` and writes `aurora_meter_event_totals` and
its own two checkpoint rows. Everything else it could touch is a channel that
would turn a *rebuild* into a *resend*, a second invoice line or a duplicate
notification. Each is asserted silent by a test, not merely intended.

The test is
`AuroraMeter.EventsReplayTest / test side effects I08 a replay enqueues nothing,
grants nothing, notifies nothing and flushes nothing`, run with
`events_outbox: AuroraMeter.Test.RecordingOutbox` and
`feature_sources: %{ai_generations: :events}` so every channel is actually
armed. The feature is events-sourced on purpose: a buffered feature would keep
the flush path out of reach and the assertion about it would prove nothing.

| Channel | How it would fire | What the test asserts | Assertion |
|---|---|---|---|
| Export intents | `AuroraMeter.Events.Outbox.enqueue/2`, called inside the record transaction | the recorder was reset after the fixture events and is never called again | `RecordingOutbox.items() == []` and `RecordingOutbox.calls() == 0` |
| Tenant PubSub | `{:aurora_meter, :usage, ...}` and `{:aurora_meter, :event, ...}` on `AuroraMeter.Broadcaster.topic/1` | subscribed before the run, nothing arrives | `refute_received {:aurora_meter, :usage, _}` and `refute_received {:aurora_meter, :event, _}` |
| Flush telemetry | `[:aurora_meter, :flush]` and `[:aurora_meter, :flush, :error]` | a handler is attached for the whole run and never fires | `refute_received {:forbidden_telemetry, _}` |
| Credit grants | `[:aurora_meter, :credits, :grant]` | same handler, same assertion | `refute_received {:forbidden_telemetry, _}` |
| The record span | `[:aurora_meter, :record, :stop]` | same handler. A replay that reached `record_events/2` would emit one per event | `refute_received {:forbidden_telemetry, _}` |
| The pending flush batch | `AuroraMeter.Store.snapshot_flush_batch/0` | no batch was ever formed | `Store.snapshot_flush_batch() == nil` |
| The dirty set | `AuroraMeter.Counter.bump/2` marking a key for the flusher | the table is emptied before the run and is still empty after | `:ets.info(Store.dirty_table(), :size) == 0` |
| Buffered counters | `aurora_meter_counters`, the only table a Pro reporter bills from | no row exists for the events-source feature | `Storage.load_counter(tenant, :ai_generations, period) == nil` |

Two further channels are closed structurally rather than by assertion, and the
reason is that there is no call site to assert on:

* **`AuroraMeter.Credits`** is not referenced anywhere in
  `lib/aurora_meter/events/replay.ex`. The grant telemetry above is the
  observable that would catch it if it ever were.
* **Host handlers.** Core calls a host handler from
  `AuroraMeter.Events.post_commit/1` only, which is reached from
  `AuroraMeter.Events.effects/2`, which the replay never calls. The symbol
  comparison in `03d-report.md` section 7 shows both functions byte-identical to
  `HEAD`.

## What the ETS re-seat does, and why it is not a side effect

After activating a generation the replay re-seats **warm** counter keys for
events-source features from the new active generation, through
`AuroraMeter.Counter.rehydrate/1`, which is `rebase/3` with `:flush`. That moves
`value` and clears `remote`. It does **not** touch `pending_flush` and does
**not** mark the key dirty, so a re-seated key cannot reach
`Store.snapshot_flush_batch/0` or `Storage.flush_batch/3`. The dirty-set
assertion above is what holds that down: it is taken after the activation and
therefore after every re-seat.

A cold key is left alone and seeds from `Storage.load_event_total/3` on its
first read, which already reads the new generation.
