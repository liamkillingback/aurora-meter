# 09b: the support matrix, and the one thing `--check-support` can catch that nothing else can

Build unit 09b, task 09.04, decision D12. Captured 2026-09-16 (UTC).

## Where it lives, and why there is not a second module

The build document asks for `AuroraMeter.SupportMatrix` with `entries/0` and
`check/1`. **That module was not created.** Build unit 05c landed
`AuroraMeter.Install.Support` after this document was written, with `rows/0`,
`supported?/1` and `report/1`, and `api-change-map.md` section 1.2 already
records it as the support module for these packages. A second module with the
same job would be the drift this unit exists to prevent, so `Install.Support` was
extended instead. The deviation is deliberate and is called out in the unit's
report; the shape the build document asked for (subject, requirement, optional,
note, plus a check that resolves the running system) is what the module provides.

Pro has no matrix of its own. Pro's `mix.exs` makes Oban a hard dependency and
Pro depends on core, so its optional set is the LiveView pair and nothing else,
and both are already rows here. A second list naming the same two dependencies
plus an OTP floor would be a copy, and the OTP 26 floor it would carry is already
stated in Pro's `README.md` and proved by 01f's `otp25-evidence` CI leg. Also
called out in the report.

## The rows, on this machine

From the real host project in `tmp/v1/09b/host/demo`, through
`mix aurora_meter.install --check-support`. Seventeen rows, one per subject:

    elixir                  1.20.1          floor 1.15.8    ok
    erlang/otp              29              floor 25        ok
    postgres                not installed   floor 13        not checked
    ecto_sql                3.14.0          floor 3.10.0    ok
    postgrex                0.22.4          floor 0.0.0     ok
    phoenix_pubsub          2.3.0           floor 2.1.0     ok
    telemetry               1.4.2           floor 1.2.0     ok
    jason                   1.4.5           floor 1.4.0     ok
    nimble_options          1.1.1           floor 1.1.0     ok
    phoenix_live_view       not installed   floor 1.0.0     absent (optional)
    phoenix_html            not installed   floor 3.3.0     absent (optional)
    plug                    not installed   floor 1.15.0    absent (optional)
    igniter                 0.8.4           floor 0.8.0     ok
    oban                    2.24.1          floor 2.17.0    ok
    telemetry_metrics       not installed   floor 0.6.0     absent (optional)
    phoenix_live_dashboard  not installed   floor 0.8.0     absent (optional)
    opentelemetry_api       not installed   floor 1.2.0     absent (optional)

**EXIT = 0.**

The Postgres row still says "not checked", with the reason in the row: a server
version can only be learned by asking the server, and an installer that connects
to a host's database to tell it about compatibility has done something the host
did not ask for. The floor is printed and the check is the host's to run.

## What this unit changed in it

**The `phoenix_live_view` floor moved from 0.20.0 to 1.0.0**, which is C9 and
D12 (`09b-components-liveview.md`). A floor a host reads and a requirement Hex
resolves have to be the same number or one of them is a lie, so a test asserts
they agree: `{:phoenix_live_view, "1.0.0", :optional}` is in
`declared_deps/0`, `mix.exs` declares `~> 1.0`, `"1.0.0"` matches it and
`"0.20.17"` does not.

**Five dependencies were missing entirely.** The matrix listed nine; `mix.exs`
declares fourteen. `phoenix_html`, `plug`, `telemetry_metrics`,
`phoenix_live_dashboard` and `opentelemetry_api` were all absent, so
`--check-support` was silent about five of the eight things it is for. A comment
in `support.ex` said a test compared the list against `mix.exs` and the README,
and named a test file that **did not exist**. A rule nothing enforces is one
already being broken (X153), and it had been broken by five entries. The
comparison now runs, in both directions on an unswitched build and in the safe
direction on a leg that removes dependencies.

**The stale-build row is new**, and it is the reason the switch is worth having.

## The stale-build row

A host that adds an optional dependency **after** `aurora_meter` was compiled
has the dependency and does not have the integration:
`AuroraMeter.Components`, `AuroraMeter.Plug.EnsureEntitled`, `AuroraMeter.Oban`,
`AuroraMeter.Telemetry.Metrics`, `AuroraMeter.LiveDashboard.Page` and
`AuroraMeter.OpenTelemetry` are each compiled behind
`if Code.ensure_loaded?(...)`, and a dependency is not recompiled because a new
one appeared beside it. Every symptom of that points at the host's own code,
which is why it is an error row with the fix in it rather than a note.

**Induced end to end, on a real host, not simulated.** The host project adds
`{:phoenix_live_view, "~> 1.0"}` to its own `mix.exs` after `aurora_meter` is
already built into it, then runs `mix deps.get` and `mix compile`. Output from
`tmp/v1/09b-checksupport.sh`:

    --- what the host now has ---
      Phoenix.Component loadable?          true
      AuroraMeter.Components compiled?     false

    --- the phoenix_live_view row, and what the check says to do ---
      phoenix_live_view  1.2.11  floor 1.0.0  NOT COMPILED IN  - AuroraMeter.Components
        was not compiled. Run `mix deps.compile aurora_meter --force` and this row goes green.
      plug               1.20.3  floor 1.15.0 NOT COMPILED IN  - AuroraMeter.Plug.EnsureEntitled
        was not compiled. Run `mix deps.compile aurora_meter --force` and this row goes green.

    Aurora Meter is not supported on this host as it stands:
      phoenix_live_view 1.2.11 is installed but its integration is not compiled: ...
      plug 1.20.3 is installed but its integration is not compiled: ...

    EXIT = 1

Then the documented remedy, because a check that reports a problem whose fix does
nothing is worth as little as a check that reports nothing:

    running: mix deps.compile aurora_meter --force
      exit=0
      phoenix_live_view  1.2.11  floor 1.0.0  ok

    EXIT = 0

**`plug` came along uninvited, and that is X331 arriving in the evidence.** The
host asked for LiveView; `phoenix_live_view 1.2` declares `plug` and `phoenix` as
**non**-optional, so `Plug.Conn` became loadable too, and `EnsureEntitled` was
equally uncompiled. A host that thought it was adding one integration was
half-adding two. Nothing else in either package would have told it so.

In suite, the same branch is driven through the real row code with an injected
probe (`Support.rows(probe: ...)`), paired with a control that runs the identical
code with the module compiled and asserts `:ok`, and a third that gives it a
version below the floor and asserts `:below_floor` wins, because a host on an old
LiveView has a version problem and telling it to recompile would send it round a
loop. Without the paired control the first test would pass for a probe that
returned `:stale_build` whatever it was given (X325).

## `--check-support` exits non-zero, and had to be made to

The Igniter definition of the task used `Igniter.add_issue/2` for an unsupported
host. **`Igniter.do_or_dry_run/2` displays issues and returns `:issues` without
setting an exit status**, so the task printed "not supported" and exited **0**. A
switch whose entire job is to answer "is this host supported" that answers only
in prose cannot be used by a CI step, an install script or a release check, which
is every place it would be used.

It now raises through `Mix.raise/1`, which is what the Igniter-less definition of
the same task already did, so both definitions behave identically. It writes
nothing by construction, so an abort leaves nothing half done. The message is
`Support.report/1` followed by `Support.problem_summary/1`, which names each
failing row and the command that fixes it.

**The same framework behaviour still applies to every other refusal in both
packages** and was not changed: `mix aurora_meter.install --feature-policy bogus`
writes nothing and exits 0, and so does Pro's refusal to schedule two expiry
workers (05c). Measured on the host project. Recorded in
`09b-install-matrix.md` and in this unit's report as an open observation rather
than worked around, because the fix is a framework-level decision and
`--check-support` is the only one of them whose contract is its exit status.
