# 09e: the self-tests, and what each one would catch

Build unit 09e, 2026-09-17. Storefront `scripts/v1/test/`, run with
`bash scripts/v1/test/run.sh`. Bash only: no Elixir, no database, no registry
and no network. Every case runs against the hermetic stubs in
`scripts/v1/test/stub`, and `lib.sh` refuses to start if `mix`, `docker` or
`gitleaks` does not resolve to a stub.

Result of the whole RUN07 suite after this unit: **21 passed, 0 failed**
(18 cases that existed before, plus this unit's three files). The three new
files carry the fourteen cases the build document asks for.

`tmp/v1/selftest/selftest.log`.

## The thing these cases exist to make impossible

A runner that reports success for work it did not do. Three of this programme's
findings are exactly that shape (`open-findings.md` X366: an Igniter refusal
wrote nothing and exited 0; the `ecto.migrate` leg that exited 0 with no tables;
X135: a suite rewriting its own evidence), and the standing rule is that a
control must be watched failing before it is trusted passing. Every case below
has a leg where the thing under test is broken on purpose, and all of them were
seen failing during development before they were seen passing.

## `20-quickstart.sh`

| # | Case | What it asserts | Result |
|---|---|---|---|
| 1 | a failing step | non-zero exit; `result: "fail"`; the failing step's own exit code (1) is recorded; every later step is present as `not_run` with a null duration, never omitted | pass |
| 2 | a required step that returns 0 without doing its job | exit **2**, `failure.reason: "required_step_skipped"`, the step's `exit_code` is **0** and its `outcome` is `not_met`. This is X366 made mechanical: the command succeeded and the archive was never installed | pass |
| 3 | the fixed interpretation sentence | present verbatim; `schema` is `aurora.quickstart.v1`; the toolchain steps are `measured: false`; and no field other than that one sentence carries the words human, median, usability, customer, typical user or average | pass |
| 4 | `measured_total_ms` | equals exactly the sum of the measured steps' durations; `excluded_total_ms` equals exactly the sum of the unmeasured ones; no measured step is counted with a null duration | pass |
| 5 | a refused database target | port 5470 (the storefront container), port 5432, and an inherited `DATABASE_URL` each exit 3 with `failure.reason: "environment"`, and **no SQL at all** reaches the stub: no `psql`, no `CREATE DATABASE`, no `DROP DATABASE`. Also asserts there is no `--database` switch to get wrong: the name is derived from the run id, so it matches the allow pattern by construction | pass |
| 6 | a credential in the environment | `HEX_API_KEY`, `AURORA_HEX_READ_KEY`, `STRIPE_API_KEY` and `HEX_HOME` each exit 3 and the refusal names the variable. `AURORA_MIXLANE`, the one named exemption, does not refuse | pass |
| 7 | an archive whose sha256 is not in the manifest | exit 3, the refusal names the manifest, and `unpacked/` is empty: nothing was extracted before the refusal (L09e-5) | pass |

## `21-clean-room-profiles.sh`

| # | Case | What it asserts | Result |
|---|---|---|---|
| a | an unknown archive hash | exit 3, `extract/` empty, reason `environment`. The case also asserts its two fixture archives are not byte identical, because they were once: built from identical inputs in the same second, `tar` produced the same bytes, the "unknown" archive's hash WAS in the manifest, and the case passed for the wrong reason | pass |
| b | a file list that differs from `package.files` | the run fails, the log prints `PRESENT BUT NOT DECLARED` and names `priv`, and the forbidden-prefix rule fires as well. **Control**: the same check on an archive that ships exactly the declared set prints "the archive ships exactly the declared set" | pass |
| c | a reachable sibling checkout | the run fails and the isolation log names the planted path. **Control**: with the plant removed, the same step answers ok | pass |
| d | the core profile's environment refusal | `HEX_API_KEY`, `AURORA_HEX_READ_KEY`, `AURORA_METER_FROM_HEX` and `STRIPE_API_KEY` each exit 3, the refusal names the variable and never prints its value. `--registry-auth-env` is refused outright: the core profile takes no credential | pass |
| e | the pro profile with no credential | exit 3, the refusal names the variable, **no consumer directory is created**, nothing is quietly skipped, and the word "profile core" appears nowhere: it does not fall back. An empty value is refused the same way as an unset one | pass |
| f | a planted credential value | the scan names the file (`HIT: planted-leak.txt`), does **not** print the value, the value appears in no recorded command line, and the run fails. **Control**: the same profile with nothing planted reports `literal hits: 0` | pass |
| g | the consumer environment allowlist | the positive leg reads `expected` and `actual` out of the isolation log and asserts they are equal. The negative leg shadows `env` with a wrapper that slips one extra variable into every `env -i`; the same step then prints `FAIL: the child environment is not the allowlist`, names `V1_SELFTEST_SMUGGLED`, and the step's status in `status.json` is `fail` | pass |
| h | I20 | `v1_no_forbidden_deps` (the shipped function from `lib/checks.sh`, not a copy) passes a planted tree holding only `ecto_sql` and refuses one holding `oban`, `plug` and `phoenix_live_view`, naming each | pass |

## `22-quickstart-interrupted.sh`

| # | Case | What it asserts | Result |
|---|---|---|---|
| i | a killed run | `quickstart.json` exists and **parses**; `result` is `incomplete`, never `pass`; the step that was in flight has `duration_ms: null` and status `incomplete`; no measured step is counted; `status.json` still validates and says `aborted` | pass |

Headless safe, for the reasons case 03 records: the runner is put in its own
session with `setsid` and run in the foreground, and a watcher subshell delivers
`TERM` to that process group only after it has **seen the long step start**. The
case asserts the delivery went to a group and that the long step was in flight,
so a signal arriving after the run finished fails the case instead of passing it.

## One thing the self-tests taught about the isolation itself

The shared `$STUB_PLAN` and `$STUB_LOG` cannot reach a `mix` that either runner
starts. Both build the child environment with `env -i` plus a closed allowlist,
and `STUB_*` is not on it. That is the isolation working exactly as specified,
and it means a case that needs particular `mix` behaviour has to supply it
through `PATH`, which is on the allowlist. Cases 1, 2 and i therefore use
case-local `mix` shadows rather than the shared stub, which also keeps them from
affecting any other case. It is recorded here because the next person to write a
case against these two scripts will otherwise spend an hour on it, as this one
did: a plan entry that is silently ignored looks exactly like a plan entry that
did not match.

The one place a `STUB_*` variable still works is `docker`, which both runners
call from their own shell rather than through `env -i`. Case f uses that: the
docker stub writes the planted value into the run directory in flight, found by
taking the newest directory under `V1_TMP_ROOT`, because the run id carries a
random suffix a case cannot know in advance.
