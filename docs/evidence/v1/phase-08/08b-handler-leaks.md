# 08b: the handler counts, before and after

Build unit **08b**, task **08.04**. Invariant **B3**, G08 bullet 2
("attach/detach tests leave no telemetry handler leaks"). Core SHA at start
`9284866`, Pro `58ce8a9`. Toolchain: Elixir 1.20.1 on Erlang/OTP 29.0.1.
Written 2026-09-16.

`:telemetry.list_handlers([])` is the whole instrument. The probe filters on the
bridge's own handler id shape, `{AuroraMeter.OpenTelemetry, name, event}`, so
"ours" and "everything else" are counted separately and a detach that took
somebody else's handler with it would show.

## 1. The run

```
mix run tmp/v1/08b_handler_leaks.exs
```

Output is in `08b-handler-leaks.log` beside this file. The shape:

| Step | Handlers under `:default` | Handlers under `:reports` | Others |
|---|---|---|---|
| before any attach | 0 | 0 | 1 (a deliberately unrelated handler) |
| after one `attach/1` | **12** | 0 | 1 |
| after five `attach/1` | **12** | 0 | 1 |
| after `attach(name: :reports)` | 12 | **12** | 1 |
| after `detach(:default)` | **0** | **12** | 1 |
| after `detach(:reports)` | 0 | **0** | 1 |
| after a second `detach` of each | 0 | 0 | **1** |

Twelve is not a magic number: it is the instrumented event list, counted from
`AuroraMeter.OpenTelemetry.Bridge.default_events/0` rather than written down.

| Base event | Form | Names |
|---|---|---|
| `[:aurora_meter, :record]` | span | 3 |
| `[:aurora_meter, :flush]` | span | 3 |
| `[:aurora_meter, :replay, :batch]` | flat | 1 |
| `[:aurora_meter, :credits, :hold_reconciliation]` | flat | 1 |
| `[:aurora_meter, :pro, :provider]` | span | 3 |
| `[:aurora_meter, :pro, :outbox, :deliver]` | flat | 1 |

The Pro rows are attached **by name**. Attaching a handler to an event that
never fires costs nothing and needs no reference to a Pro module, so a core
build with no Pro installed behaves the same and `free-pro-boundary.md`'s "core
never references a Pro module" holds.

## 2. What the test asserts, and what the script adds

`AuroraMeter.OpenTelemetryTest` carries the assertions:

* `B3 attach five times leaves exactly one handler per instrumented event`
  computes the expected count from `default_events/0` and asserts it is 12
  **and** that the handler count equals it, so a change to the event list
  changes both halves together rather than silently moving the goalposts;
* `B3 detach removes every handler under the name and leaves unrelated handlers
  alone` attaches an unrelated handler on `[:aurora_meter, :flush, :stop]` first
  and asserts it survives;
* `B3 two names coexist and detach independently`.

The script above adds two things a test does not print: the handler **ids**
themselves, so the evidence shows which handlers rather than only how many, and
a second `detach/1` of each name, which is the "safe to call when nothing is
attached" half.

## 3. The control that made the idempotency claim honest

`c11-attach-does-not-detach-first` removes the `detach(name)` that `attach/1`
runs before it attaches. Its verdict is in section 7 of
`08b-optional-integrations.md`, with what it showed and what was done about it.

The thing worth reading is that `:telemetry.attach/4` refuses a duplicate id and
returns `{:error, :already_exists}`, so a count of handlers cannot distinguish
"attach detaches first" from "telemetry refuses the second". A count is
therefore not enough to prove the property, and the test that proves it has to
attach twice with **different options** and assert the second set is the one in
force.

## 4. A handler that raises

`AuroraMeter.OpenTelemetryTest` / `test a handler that raises is detached by
telemetry and the other handlers keep producing spans` attaches the bridge twice
under two names with two tracers, one of which raises in `record_span/5`. After
one emit:

* `:a` has **11** handlers, not 12: `:telemetry` detached the one that raised
  and only that one;
* `:b` still has 12 and still produced a span;
* a second emit still produces a span through `:b`.

A test that attached only one name could not tell "telemetry detached the
offending handler" from "the whole bridge stopped", which is the reason there
are two.

## 5. What this does not prove

`AuroraMeter.OpenTelemetry.attach/1` itself, the public function, was not
executed: the module is compiled only when `opentelemetry_api` is installed and
it was not obtainable in this unit (`open-findings.md` **X335**). Everything
above is `AuroraMeter.OpenTelemetry.Bridge.attach/1`, which is what
`attach/1` delegates to in four lines, and the handler ids the evidence shows
are the ids the public function would leave.
