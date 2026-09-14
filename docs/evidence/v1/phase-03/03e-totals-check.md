# 03e: where a CHECK constraint applies in an upsert, measured

Build unit 03e's document says the `CHECK (quantity >= 0)` 03a put on
`aurora_meter_event_totals` "is the backstop, and the adapter maps a violation
of it to `{:error, {:invalid, [quantity: :exceeds_original]}}`". That is right
about what a violation means and wrong about when one happens, and the
difference decides how a correction's totals delta has to be written.

## What was measured

Probe: `tmp/v1/03e/probes/probe_totals_check.exs`. Log:
`tmp/v1/03e/logs/probe-check-constraint.log`. Run 2026-09-14, port 5490,
database `aurora_meter_test`.

```
server: PostgreSQL 16.13 (Debian 16.13-1.pgdg13+1) on x86_64-pc-linux-gnu,
        compiled by gcc (Debian 14.2.0-19) 14.2.0, 64-bit
```

A throwaway table with `CHECK (quantity >= 0)` and one row holding `10`.

| Statement | Row that would result | Outcome |
|---|---|---|
| `INSERT ... VALUES ('a', -3) ON CONFLICT (k) DO UPDATE SET quantity = t.quantity + EXCLUDED.quantity` | 7 | **REFUSED**, `:check_violation` |
| `UPDATE ... SET quantity = quantity + (-3)` | 7 | accepted, value 7 |
| `UPDATE ... SET quantity = quantity + (-100)` | -93 | REFUSED, `:check_violation` |

**The CHECK is applied to the tuple the INSERT proposes, before the conflict is
resolved.** Proposing `-3` against a row holding `10` is refused even though the
row the UPDATE would leave is `7` and satisfies the constraint.

That is not a surprise once stated, but the build document assumed the opposite,
and the first implementation of `record_correction/2` used the same
`INSERT ... ON CONFLICT DO UPDATE` statement `record_events/2` uses. Every
correction failed, and the failure arrived as the adapter's own backstop warning
saying the cumulative bound must be wrong, which it was not.

## What the adapter does instead

`AuroraMeter.Storage.Ecto`'s `move_total/2`, two statements per key and
generation:

1. `INSERT INTO aurora_meter_event_totals (..., quantity, events) VALUES (..., 0, 0) ON CONFLICT DO NOTHING`
2. `UPDATE aurora_meter_event_totals SET quantity = quantity + $delta, events = events + $n WHERE ...`

The proposed tuple is `0`, which no non-negative constraint can refuse, and the
delta lands on the UPDATE path, where the third row of the table above shows the
constraint still doing its job. The backstop is kept and the live path works.

`record_events/2`'s own `apply_totals/4` is untouched: a usage event's delta is
never negative, so the single-statement upsert is still correct there, and that
function is on the path this unit must not change.

## The general rule

**A constraint applies where the tuple is formed, not where the value ends up.**
Same family as `open-findings.md` X104 ("a size constraint must measure the
representation the limit is about") and X105 ("`NOT VALID` buys a fast ALTER,
not a grace period"): three ways of assuming a constraint is evaluated somewhere
other than where it is.

## Handoff to 03d

A **building** generation whose replay scan has not yet reached a key has no
totals row, so the zero row step 1 creates is what a correction's negative delta
lands on, and the constraint refuses it. No building generation exists until
replay ships, and reconciling the dual write with the scan's absolute writes is
replay's own design problem. It is named in a comment on `apply_correction_totals/2`
so 03d meets it while reading the code rather than in production.
