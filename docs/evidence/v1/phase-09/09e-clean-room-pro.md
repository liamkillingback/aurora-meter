# 09e: the clean-room Pro profile (G09 bullet 2)

Build unit 09e, 2026-09-17. `scripts/v1/package-smoke.sh --profile pro`.

G09 bullet 2: "Clean-room Pro profile resolves its private package and the
released core pairing with least privilege read access, and keys never appear in
source, screenshots, lockfiles or logs."

## Lead with what is not met

**The private package could not be resolved, so the first half of G09 bullet 2
is NOT MET.** The credential available on 2026-09-17 carries the `api`
permission and not the `repository:phxtemplates` permission, and package
resolution needs the second one. Detail below, measured rather than inferred.

**The released core pairing was resolved, and it does not compile.** Aurora
Meter Pro's declared requirement on core admits published core 0.4.0, Hex
resolves 0.4.0 because that is the newest published version that matches, and
Pro's code then fails type checking against it. Filed as X420 and it is release
blocking.

**The key hygiene half is met, and it is met with a measurement rather than an
assurance.** See the scan section.

## The credential, and how far it actually reaches

The key was supplied by the owner in a file outside the repository tree
(`mode 600`, owner `liamk`, 32 bytes). Its value is not in this file, not in any
log, not in any run directory and not in this repository. What follows is its
observed behaviour.

**What it can do.** Read on the `hex.pm/api` domain:

```
GET /api/users/me                                    404   (no user: it is an organisation key)
GET /api/repos                                       200   [hexpm, phxtemplates]
GET /api/repos/phxtemplates                          200
GET /api/repos/phxtemplates/packages                 200   (aurora_meter_pro is listed)
GET /api/repos/phxtemplates/packages/aurora_meter_pro 200  (releases 0.3.0 back to 0.1.0)
POST /api/keys                                       401   (it cannot manage keys)
```

**What it cannot do.** Read on the `repo.hex.pm` domain, which is where
`mix deps.get` fetches from:

```
GET https://repo.hex.pm/repos/phxtemplates/names                        401
GET https://repo.hex.pm/repos/phxtemplates/versions                     401
GET https://repo.hex.pm/repos/phxtemplates/packages/aurora_meter_pro    401
GET https://repo.hex.pm/repos/phxtemplates/names  (no Authorization)    401
```

The last line is the control: with this key the repository domain answers
exactly what it answers to no key at all. The key adds nothing there.

**End to end, in the clean room** (`package-smoke-20260917T045454Z-691bdd`,
`--profile pro --mode registry --pro-version 0.3.0`):

```
mix hex.organization auth phxtemplates --key <the key>
  Failed to authenticate against organization repository with given key because of:
  key not authorized for this action
  exit 1

mix hex.organization list
  phxtemplates

hex-home/hex.config exists, 177 bytes, mode 644
  the key value is stored there in plain text

mix hex.package fetch aurora_meter_pro 0.3.0 --repo phxtemplates
  ** (Mix.Error) Unknown repository "phxtemplates", add new repositories with the
     `mix hex.repo add` task
```

And with the dependency declared rather than fetched by hand:

```
** (Mix) No package with name aurora_meter_pro (from: mix.exs) in registry
```

### Three commands, three answers, and two of them wrong

This is the finding worth carrying forward, and it is filed as X418.

1. `mix hex.organization auth` **exits 1** and says the key is not authorised.
   Correct.
2. It nonetheless **writes the key into `$HEX_HOME/hex.config`, in plain text,
   mode 644**, on the failing path.
3. `mix hex.organization list` then prints `phxtemplates`, as though the
   organisation were authorised. Hex's own registry server disagrees a second
   later: `Unknown repository "phxtemplates"`.

So a CI leg, or a runbook step, that ran `mix hex.organization auth` and then
checked `mix hex.organization list` would report success on a credential that
can read nothing, while leaving that credential on disk. That is directly
relevant to the owner decision recorded in X409 about whether a read key belongs
in CI at all: whatever is decided, `hex.organization list` is not the check.

The profile's own outcome assertion is therefore **not** `list`, and not `$?`
either. It is "can this credential actually read the private repository", asked
by fetching the package. Written down in the script beside the measurement that
made it necessary.

### What a working credential looks like

`mix help hex.organization` says `mix hex.organization key ORGANIZATION generate`
issues a key that "by default ... sets the `repository:organization_name`
permission which allows read-only access to the organization's repository". That
is the shape the Pro profile needs and the shape `09e-prerequisites.md` tells a
customer to use. It is still least privilege: it can read one organisation's
packages and it can publish nothing.

## What was proved without it

Two further legs were run, because "the credential is wrong" is not a reason to
learn nothing about the package.

### Leg P2: the Pro archive with core from the registry

`package-smoke-20260917T045501Z-2212f1`. The consumer declares **only**
`aurora_meter_pro` (as a path dependency on the unpacked archive), plus `oban`
and `stripity_stripe`. Core is not named at all, so it can only arrive through
Pro's own registry requirement, with `AURORA_METER_FROM_HEX=1` set in the child's
explicit environment so `core_dep/0` takes the Hex branch.

```
* Getting aurora_meter (Hex package)
  aurora_meter 0.4.0
```

Then:

```
== Type checking failed with errors ==
AuroraMeter.Checkpoints is undefined (module AuroraMeter.Checkpoints is not available)
AuroraMeter.Event is undefined (module AuroraMeter.Event is not available)
AuroraMeter.Exporter.Item is undefined (module AuroraMeter.Exporter.Item is not available)
AuroraMeter.Schema.PlanTransition is undefined (module AuroraMeter.Schema.PlanTransition is not available)
could not compile dependency :aurora_meter_pro
```

Pro's `core_dep/0` declares `{:aurora_meter, "~> 0.4 or ~> 0.5"}`. `~> 0.4`
admits everything from 0.4.0 to below 1.0.0, Hex picks the newest published
match, and that is 0.4.0 because 0.5.0 is not published. Pro's code needs four
core modules that exist only at 0.5.0. **A customer resolving Pro from the
registry today gets a tree that does not compile.**

This is exactly the failure a sibling-path build can never find, which is what
`v1-release.md` 2.2 means by "path-based success is insufficient". The fix is
Pro's requirement, which must name the core version it actually needs.

### Leg P3: the Pro archive with the core archive

`package-smoke-20260917T045600Z-3a2e79`. **Pass**, every step:

```
pass  smoke.pro.facts        pass  smoke.consumer.deps
pass  smoke.pro.metadata     pass  smoke.consumer.compile
pass  smoke.pro.files        pass  smoke.consumer.tree
pass  smoke.consumer.new     pass  smoke.consumer.database
pass  smoke.consumer.scaffold pass smoke.consumer.install
pass  smoke.isolation        pass  smoke.consumer.pro_generators
                             pass  smoke.consumer.migrate
                             pass  smoke.consumer.proof
                             pass  smoke.pro.key_scan
                             pass  smoke.cleanup
                             pass  v1.secret_sweep
```

So the Pro archive itself is sound: it installs, both migration generators run,
both migrations apply, and the application boots and meters:

```
first counter: usage=1
hard quota: refused past the limit
SMOKE_OK
```

`mix aurora_meter_pro.gen.migration` ran in a host whose modules had never been
loaded, which is X394's exact condition, and it worked: repair unit R7's fix
holds outside its own test VM.

## The Pro archive's metadata and file list

```
version matches: 0.3.0
contents (74 entries)
no test/, demo/, priv/plts/, .env or erl_crash.dump in the archive
licence present: LICENSE.commercial
Pro names aurora_meter as a registry requirement
source_ref v0.3.0 exists as a tag in product-workspaces/aurora_meter_pro
no high signal secret findings in the extracted tree

declared in mix.exs package.files (7 entries):
.formatter.exs  CHANGELOG.md  LICENSE.commercial  NOTICE.md  README.md  lib  mix.exs
top-level entries actually in the archive:
.formatter.exs  CHANGELOG.md  LICENSE.commercial  NOTICE.md  README.md  lib  mix.exs
the archive ships exactly the declared set
```

Seven entries, not the eight the build document expected: Pro's `package.files`
in `mix.exs:247` is core's list with `LICENSE` replaced by `LICENSE.commercial`,
not with it added.

**"Pro names aurora_meter as a registry requirement" only because the archive was
built with `AURORA_METER_FROM_HEX=1`.** Built with the sibling checkout visible,
`core_dep/0` returns a path dependency, Mix excludes path dependencies from
package metadata, and the tarball declares no `aurora_meter` requirement at all.
Filed as X421, because a release rehearsal that forgets the switch produces a
tarball Hex would accept and no customer could use.

## The key scan (the half of bullet 2 that is met)

Run twice on every Pro leg: once with the isolated `HEX_HOME` still present, so
a reader can see exactly where Hex put the credential, and once after it is
deleted, which is the gate.

With `HEX_HOME` present:

```
credential scan (HEX_HOME present) over tmp/v1/package-smoke-<runid>
  HIT: hex-home/hex.config (the file is named; the value is not printed)
  files scanned: 3074
  literal hits: 1
```

After `rm -rf hex-home`:

```
credential scan (HEX_HOME deleted) over tmp/v1/package-smoke-20260917T045600Z-3a2e79
  files scanned: 3036
  literal hits: 0
  credential-shaped strings in what this run produced: none
  for completeness: 2 file(s) under deps/ carry a Stripe-shaped example string.
  Those are third-party package contents, not output of this run, and none of
  them matched the literal key.
```

**Zero literal occurrences** of the key's value across every file in the run
directory after the isolated `HEX_HOME` is removed: `mix.lock`, `mix.pro.lock`,
every step log, `status.json`, the extracted archives, the consumer tree and the
fetched dependency source. The same is true of every other Pro run in this unit.

Three things about that scan are worth stating rather than implying:

- **It names files, never values.** Self-test 21f plants the value in the run
  directory and asserts the scan prints `HIT: planted-leak.txt` and does **not**
  print the value, and that the value appears in no recorded command line.
- **The shape scan excludes `deps/`, and says so.** `stripity_stripe` ships
  `sk_test_...` in its own README and module documentation. Calling a third
  party's documented example a leak from this run would be a false alarm that
  trains a reader to ignore the real one. The **literal** scan has no exclusion
  at all.
- **The one place the key does land is `hex.config`, and that is Hex's doing.**
  Deleting the isolated `HEX_HOME` removes the local authorisation with it,
  which is why the profile does that rather than calling `deauth`.

The residual, written down rather than hidden: `mix hex.organization auth
ORGANIZATION --key KEY` is the only non-interactive form Hex documents, so the
value is in one child process's argv for the duration of one command. It is
never in a recorded command line, because the step is a shell function taking no
arguments and `v1_step` records the function's name. It is registered with the
runner's sanitiser by value, so even an unexpected echo by a child would be
redacted before it reached a file.

## Isolation

Identical to the core profile and asserted the same way, plus one line that only
the Pro profile needs:

```
5. the operator HOME is untouched by this run
   ok: ~/.hex/hex.config does not mention phxtemplates
```

Checked again by hand after every leg: the operator's `~/.hex/hex.config` does
not contain the key's value and does not mention `phxtemplates`. The
authorisation lived and died inside the run directory.

## Refusals

- `--profile pro` with the named variable unset: **exit 3**, the refusal names
  the variable, **no consumer directory is created**, nothing is recorded as a
  skip, and it does not fall back to the core profile. Measured live and
  self-tested (case 21e), including the empty-value case.
- `--profile core` with `--registry-auth-env`: exit 3. The free profile takes no
  credential, by construction.

## Run index

| Run | Command | Result |
|---|---|---|
| `package-smoke-20260917T045454Z-691bdd` | `--profile pro --mode registry --pro-version 0.3.0 --core-version 0.4.0 --registry-auth-env AURORA_HEX_READ_KEY` | fail at `smoke.pro.organization_auth` |
| `package-smoke-20260917T045501Z-2212f1` | `--profile pro --mode local --pro-archive <provisional> --pro-version 0.3.0 --core-version 0.4.0` | fail at `smoke.consumer.compile`, core 0.4.0 |
| `package-smoke-20260917T045600Z-3a2e79` | the same plus `--core-archive <provisional 0.5.0> --core-version 0.5.0` | pass |
