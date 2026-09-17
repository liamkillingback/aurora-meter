# 09e: what a first install actually requires

Build unit 09e, 2026-09-17. Measured on one machine by `scripts/v1/quickstart.sh`
in the storefront repository. Every claim below is either something the script
verified before it started, or something it installed itself and recorded.

This file is the source `10b` and `10c` copy prerequisite copy from. Nothing here
is an estimate.

## The short answer

To meter a first counter with the free `aurora_meter` package you need Elixir,
Erlang/OTP, a Postgres database and network access to `hex.pm`. You do not need
an account with anyone, you do not need a key of any kind, you do not need a
payment provider, and you do not need Aurora Meter Pro.

## Required

| Requirement | What the measured run used | Note |
|---|---|---|
| Elixir | 1.20.1 | The package declares `elixir: "~> 1.15"`. The supported pairs are in `09b-support-matrix.md`; 1.20.1 is the one this measurement was taken on, not a floor. |
| Erlang/OTP | 29, erts 17.0.1 | |
| Postgres | 16.13 | Reached over TCP. The run creates its own disposable database and drops it. |
| A Phoenix or plain Ecto application | `mix phx.new` 1.8.13 | A Phoenix application is not required by the library. The measured run generates one because that is the commonest starting point, and the `core` clean-room profile proves the same install in a plain `mix new` application with no Phoenix, no LiveView and no Plug. |
| Network access to hex.pm | yes | For the package and its dependencies. Nothing else is contacted: the library does not phone home (D11). |
| `{:igniter, "~> 0.8", only: [:dev]}` | yes | Only to run `mix aurora_meter.install`. It is a development-time tool and the running application never loads it. A host that does not want it can follow the printed steps instead. |

## Explicitly not required

- **No account.** Not with aurorameter.com, not with hex.pm, not with anyone.
- **No credential.** `scripts/v1/package-smoke.sh --profile core` refuses to run
  if `HEX_API_KEY`, or any `AURORA_` or `STRIPE_` variable, is present in its
  environment, and it names the variable rather than unsetting it quietly. The
  clean-room core run resolves and installs with an empty `MIX_HOME` and an
  empty `HEX_HOME` and no authorisation of any kind.
- **No payment provider.** Stripe belongs to Aurora Meter Pro. The free package
  contacts no provider.
- **No LiveView, no Plug, no Oban, no metrics library.** The clean-room core
  consumer resolves `ecto_sql`, `postgrex` and `phoenix_pubsub` and nothing
  else, and the run reads its own resolved dependency tree back to prove it
  (I20).
- **No sibling checkout of the package.** The clean room asserts that no
  `aurora_meter` or `aurora_meter_pro` directory is reachable from any parent of
  the application, so nothing on disk can rescue a resolution.

## Aurora Meter Pro adds

| Requirement | Note |
|---|---|
| A licence, and with it a read key for the private Hex organisation `phxtemplates` | The key must carry the **repository** permission for that organisation, which is what `mix hex.organization key phxtemplates generate` issues by default. A key with only the `api` permission can read the organisation's metadata over `hex.pm/api` and **cannot resolve the package**: `mix deps.get` answers "No package with name aurora_meter_pro". Measured, 2026-09-17, in `09e-clean-room-pro.md`. |
| `{:oban, "~> 2.17"}` and `{:stripity_stripe, "~> 3.2"}` | Pro requires both. |
| A Stripe account | For the provider path only. `09d` owns that proof. |

## What the measured window does and does not cover

The quickstart's number covers **first-meter setup only**: generating the
application, adding the dependency, resolving it, running the installer,
migrating, and proving one counter and one hard quota. It does **not** include
installing Elixir, installing Erlang, provisioning Postgres, or installing the
Phoenix generator archive. Those steps are in the timing file too, marked
`measured: false`, so a reader can see exactly what was left out and what it
cost on this machine.
