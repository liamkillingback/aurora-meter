# 09e: the 11c / 09e / 11c ordering, and what 09e could not do without it

Build unit 09e, 2026-09-17.

## The ordering the build documents agree on

`dependency-map.md` section 4 records a circularity and its resolution:

1. **11c** builds the candidate archives from the candidate branch with
   `mix hex.build` and writes `docs/evidence/v1/phase-11/candidates.json` with
   each archive's path, version, sha256, source SHA, toolchain and file count.
   Nothing is published.
2. **09e** runs `package-smoke.sh --profile core` and `--profile pro` against
   those exact archives, and `quickstart.sh --source archive` against the core
   candidate.
3. The **owner** publishes (phase 12, D13).
4. **11c** reruns `package-smoke.sh --mode registry --core-version <published>`
   and `quickstart.sh --source hex --core-version <published>`, proving that
   what was published is what was smoked. Any difference between the two runs is
   a release defect, not a documentation problem.

## Step 1 has not happened

Phase 11 has not started. There is no `docs/evidence/v1/phase-11/` in any of the
three repositories, there is no `candidates.json` anywhere in the tree, and
there are no candidate archives. Checked on 2026-09-17 by `find` across the
whole repository.

So step 2 could not be run as written, and **G09 bullet 6 ("core, Pro and sample
tests build from the exact candidate archives used for release rehearsal") is
not met by this unit**. There is no release rehearsal and no candidate.

## What was done instead, and what each artifact actually is

Rather than approximate a candidate, 09e ran against two kinds of artifact that
do exist today, and labelled each one. `tmp/v1/09e/artifacts/09e-artifacts.json`
carries them in the same shape `candidates.json` will have, with a `provenance`
field that says which is which, and a `note` field whose first sentence is
"THIS IS NOT 11c CANDIDATES.JSON".

| Artifact | sha256 | What it is |
|---|---|---|
| `aurora_meter-0.4.0.published.tar` | `9e38d799514685b6657f4e3cfecc64f88eea03ca6180317ce307f98c1c3c0c96` | **registry.** The tarball hex.pm is serving for `aurora_meter` 0.4.0 right now, fetched with no credential, with Hex verifying its own checksum on fetch. The digest matches the historical entry in Pro `docs/evidence/phase-17/package-builds.json`, which is the first time that record has been checked against the registry. |
| `aurora_meter-0.5.0.provisional.tar` | `200fb12305779ff8ff8a71297bf6ab4592f5cc87710f2628443f392602d60a62` | **provisional.** Built here by `mix hex.build -o` from the working tree at core `977a66a`, with uncommitted work present. Not tagged, not published, not a release candidate. |
| `aurora_meter_pro-0.3.0.provisional.tar` | `5160fa5e300a9f292cf99ceaf2808db00e06724cfc9e2cf2eedbd22179696143` | **provisional.** Built here from the working tree at Pro `ebf8671`, with `AURORA_METER_FROM_HEX=1` set so that Pro's `core_dep/0` takes its registry requirement rather than the sibling path. Without that switch the tarball would declare no `aurora_meter` requirement at all, because a path dependency is excluded from package metadata. That is worth knowing before a release rehearsal: **`mix hex.build` for Pro must be run with `AURORA_METER_FROM_HEX=1`, or it produces a tarball Hex would publish and nobody could use.** |

Neither `mix hex.build` invocation wrote anything into a package repository:
`-o` put both tarballs under the storefront's `tmp/v1/`, and
`git status --porcelain` in both package repositories is byte identical before
and after.

## What the provenance machinery did, so 11c inherits a working one

`L09e-5` says an artifact is identified by its sha256 and its recorded
provenance, never by its filename. Both runners implement it:

- `quickstart.sh --manifest PATH` and `package-smoke.sh --manifest PATH` compute
  each archive's sha256 and refuse before unpacking anything if it is not in the
  manifest. Self-tested (case 20's last block and case 21's case a), including a
  leg that proves nothing was extracted before the refusal.
- Without `--manifest` a run is still allowed, and says so: `quickstart.json`
  carries `source.provenance: "UNVERIFIED: no manifest was supplied..."`. An
  unprovenanced run that admits it is worth more than no run at all, and it
  cannot be mistaken for a provenanced one later.
- The manifest's `provenance` field changes one check and only one: a
  **provisional** archive is allowed to have no git tag for its `source_ref`,
  because a local build of an unreleased version cannot have one. A **candidate**
  or **registry** artifact with no tag still fails, which is the behaviour 11c
  needs. The core 0.5.0 archive exercised this: the working tree is at 0.5.0 and
  the repository's newest tag is `v0.4.0`.

## Instruction for 11c

When the candidate archives exist:

```bash
# 1. Point the same runners at them. Nothing else changes.
bash scripts/v1/quickstart.sh --source archive \
  --archive tmp/v1/candidates/aurora_meter-<v>.tar \
  --manifest <core>/docs/evidence/v1/phase-11/candidates.json --db-port 5490

bash scripts/v1/package-smoke.sh --profile core --mode local \
  --core-archive tmp/v1/candidates/aurora_meter-<v>.tar --core-version <v> \
  --manifest <core>/docs/evidence/v1/phase-11/candidates.json \
  --examples all --sample-dir product-workspaces/aurora_meter/examples/aurora_meter_example_ai

bash scripts/v1/package-smoke.sh --profile pro --mode local \
  --pro-archive tmp/v1/candidates/aurora_meter_pro-<v>.tar --pro-version <v> \
  --manifest <core>/docs/evidence/v1/phase-11/candidates.json \
  --registry-auth-env AURORA_HEX_READ_KEY
```

`candidates.json` must carry, per artifact, at least `package`, `version`,
`path`, `sha256` and `provenance`. `provenance` must be `candidate` for a
release candidate, so the tag check stays hard.

After the owner publishes:

```bash
bash scripts/v1/quickstart.sh --source hex --core-version <published> --db-port 5490
bash scripts/v1/package-smoke.sh --profile core --mode registry --core-version <published>
bash scripts/v1/package-smoke.sh --profile pro --mode registry \
  --pro-version <published> --core-version <published> \
  --registry-auth-env AURORA_HEX_READ_KEY
```

The published core run has already been rehearsed here against 0.4.0 and it
**fails**, at the installer's own output, for the reason X374 names. That is
recorded in `09e-clean-room-core.md` and it is the strongest argument this unit
produces for running the post-publication leg rather than assuming it.

The Pro registry leg needs a credential that carries the **repository**
permission for `phxtemplates`. The key available on 2026-09-17 carries only the
`api` permission and cannot resolve the package; see `09e-clean-room-pro.md`.
