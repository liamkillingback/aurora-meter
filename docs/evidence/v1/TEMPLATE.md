# V1 phase report template

Copy this file to `docs/evidence/v1/phase-NN/<report>.md` and fill every section.
The seven sections below are the required contents of a phase report, transcribed
from `v1-release.md` section 1.2. Do not remove a section: if it does not apply,
write why.

> **Standing rule for every evidence file.** Do not store credentials, customer
> identities, full payment payloads or unsanitised logs. Evidence contains
> synthetic tenant ids, mode (test or live), object references where appropriate,
> checksums and sanitised outcomes only. Never print or copy `config/secrets.exs`.
> Never invent a result: if a command was not run, say so.

## 1. Tasks, repository and revision

Task ids completed, the repository, and the exact source SHA. For uncommitted
preparation, give a patch checksum and state explicitly that the tree is dirty.

## 2. Environment

Schema versions, the core and Pro package pair, Elixir and OTP versions, operating
system, Postgres version, and dependency lock hashes (`sha256sum mix.lock`).

## 3. Commands and logs

Every command, its exit code, the full log artifact path and that artifact's
sha256, the test seed, and UTC start and end timestamps.

## 4. Results

Expected versus actual for each command, accounting reconciliation totals where
money is involved, and any known limitations of what was proven.

## 5. Changes

Changes to public APIs, configuration keys, migrations, telemetry, documentation
and operational procedures.

## 6. Open defects

Each with a reproduction, a severity, the affected invariant id and the next task
that owns it. A skipped test is listed here and is never omitted.

## 7. Handoff

What a fresh agent needs to continue without conversation history: where the work
stopped, what to read, what must not change, and the next verification target.
