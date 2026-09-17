# 09e: the measured quickstart

Build unit 09e, 2026-09-17. `scripts/v1/quickstart.sh` in the storefront
repository; the timing file of record is `09e-quickstart.json` beside this one,
copied verbatim from `tmp/v1/quickstart-20260917T052340Z-574bb0/quickstart.json`.

## The interpretation, first, because everything below is read through it

> Scripted agent execution on one machine. Not a human median, not a usability
> result, not a customer measurement.

That sentence is written verbatim by the script into every timing file. It is
not computed and not configurable, and `20-quickstart.sh` asserts it is present
and that no other field in the file carries the words human, median, usability,
customer, typical user or average.

## The number

**Measured first-meter setup: 42.5 seconds** on the run of record.

Six passing runs of the final script, the last two against the script exactly as
it shipped:

| Run | `measured_total_ms` | Machine (load average, 24 cores) |
|---|---|---|
| `quickstart-20260917T044928Z-50fe92` | 41,615 | not recorded |
| `quickstart-20260917T050226Z-aea8c6` | 41,681 | 5.66 at start, 5.41 at end |
| `quickstart-20260917T050323Z-4fb61d` | 44,550 | 5.41 at start, 7.38 at end |
| `quickstart-20260917T050451Z-8d496a` | 97,766 | 5.19 at start, **23.40** at end |
| `quickstart-20260917T052235Z-fca0ad` | 44,292 | 5.20 at start, 5.60 at end |
| `quickstart-20260917T052340Z-574bb0` (record) | 42,528 | 5.60 at start, 6.04 at end |

The fourth run is not a different result, it is a different machine: a
neighbouring build unit's work drove the load average to 23.4 on 24 cores while
it was in flight. It is kept here rather than discarded, because "how long this
takes" is not independent of what else the computer is doing, and because
`open-findings.md` X416 is exactly this shape in the other direction. The load
average before and after each run is recorded for the same reason, and the runner
waits for both package build lanes to be free and for the load to fall below six
before it starts. Three earlier runs, of a script that differed in details,
measured 45,497, 41,329 and 40,502 ms, and the first successful run of all,
taken on a colder machine, measured 89,455 ms.

So: **median 42.5 seconds across the five uncontaminated runs, range 41.6 to
44.6 seconds, and 97.8 seconds in the one run whose neighbour was at load 23.**

## Against the fifteen minute target

Fifteen minutes is 900,000 ms. The slowest measured run is **11 percent** of it
and the fastest is **under 5 percent**. The target is met with a very large
margin, and the honest way to say that in public copy is to give the measured
number rather than the target.

`10b` should take the number and the caveats from here, not the target from the
programme document. A figure nobody has timed is a guess, and this one has now
been timed ten times.

## What is inside the measured window

| Step | Measured | Duration (record run) |
|---|---|---|
| verify the toolchain | no | 557 ms |
| install the pinned `phx_new` archive into the isolated `MIX_HOME` | no | 3,938 ms |
| assert the clean room is clean | no | 258 ms |
| `mix phx.new` | **yes** | 731 ms |
| add `{:aurora_meter, ...}` and point the app at a disposable database | **yes** | 314 ms |
| `mix deps.get` (cold cache) | **yes** | 10,463 ms |
| record what was resolved | no | 813 ms |
| `mix aurora_meter.install` | **yes** | 24,719 ms |
| `mix ecto.create` and `mix ecto.migrate` | **yes** | 4,587 ms |
| the proof: a first counter and a hard quota | **yes** | 1,714 ms |
| write the evidence and drop the disposable database | no | 852 ms |

`measured_total_ms` 42,528. `excluded_total_ms` 6,418. The self-test asserts
both are exactly the sums of their step sets.

## What is outside it, and why

`excluded_from_measurement` in the JSON lists five steps:

1. **verifying the toolchain.** Elixir, Erlang and Postgres are prerequisites. A
   reader who does not have them is installing a language, not a meter.
2. **installing the pinned `phx_new` archive.** Toolchain, and pinned so that two
   runs are comparable at all.
3. **asserting the clean room is clean.** Harness work. A reader does none of it.
4. **recording what was resolved.** Harness work.
5. **writing the evidence and dropping the database.** Harness work.

The single largest measured step is the installer at 24.7 seconds, and most of
that is compiling the dependency tree, which Igniter needs before it can run.

## What the run actually proved

The proof script the run executes is deliberately two claims and nothing else:

```
flush: 2 pending entries written
first counter: usage=1
hard quota: the reservation past the limit was refused
final usage=100 limit=100
QUICKSTART_OK
```

- **A first counter**: one `AuroraMeter.track/2`, one `AuroraMeter.Flusher.flush/0`,
  and `AuroraMeter.usage/2` reads 1 back out of the database-backed counter.
- **A hard quota**: 99 further reservations through `AuroraMeter.with_quota/3`
  succeed and the hundredth is refused with `{:error, :limit_exceeded}`. The
  limit is `limit :ai_generations, 100, :hard` in the starter plans module the
  **installer itself wrote**, not a hand-built variant.

A quickstart that proved five things would be a tutorial, not a measurement.

The build document's sketch of that script had `:ok = AuroraMeter.Flusher.flush()`.
`flush/0` returns `{:ok, count}`. The first real run of the proof is what found
it, which is the argument for running a proof rather than reasoning about one.

## Reproducing it

```bash
bash scripts/v1/quickstart.sh --source archive \
  --archive tmp/v1/09e/artifacts/aurora_meter-0.5.0.provisional.tar \
  --manifest tmp/v1/09e/artifacts/09e-artifacts.json \
  --db-port 5490
```

The pins are in `scripts/v1/versions.env` and the run records the ones it used
in `host`. Two runs are only comparable when their pins match.

## Negative results, stated so a green run is not over-read

- **The archive is not a release candidate.** `source.provenance` says
  "verified against the named manifest", and that manifest is
  `tmp/v1/09e/artifacts/09e-artifacts.json`, whose own first sentence is "THIS IS
  NOT 11c CANDIDATES.JSON". See `09e-sequence.md`.
- **A fresh-database run proves the DDL and nothing about upgrades.** The
  migration step exercises the bounded generated files on an empty database:
  the DDL and the concurrent-index path. It exercises none of the data steps,
  because `schema-migration-map.md` S2 and S5 have nothing to convert on an
  empty database. `11a` owns the populated fixtures. A green quickstart is not
  migration coverage.
- **It measures one machine once.** Nine times, now, but still one machine.
- **The `--source hex` variant has not been run against a V1 core**, because no
  V1 core is published. It was run against the published 0.4.0 and it failed;
  see `09e-clean-room-core.md`.
