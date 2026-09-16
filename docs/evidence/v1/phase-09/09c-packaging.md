# 09c: the sample is not in the published archive (I21)

`mix.exs` declares `package[:files]` as an explicit allow list, so everything
outside it is excluded by construction rather than by an ignore rule:

```elixir
files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md NOTICE.md)
```

That line is unchanged by this unit. What this unit adds is a test that says so,
because until now the exclusion was a property of a `~w` literal nothing checked.

## 1. `mix hex.build`

Built with the tarball written **outside** the package tree
(`tmp/v1/09c-pack.sh`). A bare `mix hex.build` drops
`aurora_meter-<version>.tar` into the package root, which is X365's shape, and
there is already one there from somebody's earlier run.

```
$ mix hex.build --output /tmp/09c_aurora_meter.tar
Package checksum: ac69447ef1c30d411c8747235b3628b437a6db2a904727374537e5ceac825fb0
Saved to /tmp/09c_aurora_meter.tar
```

### Top-level entries

```
.formatter.exs
CHANGELOG.md
LICENSE
NOTICE.md
README.md
lib
mix.exs
```

Seven, exactly the allow list. **125 files, 519,680 bytes.**

### Any path mentioning `examples` or `demo`

```
matches=0
```

### The grep was watched matching first

```
=== control: the same grep against a listing that DOES contain them ===
2
```

The same expression, `grep -E '(^|/)(examples|demo)(/|$)'`, run over a planted
three-line listing containing `examples/aurora_meter_example_ai/mix.exs` and
`demo/mix.exs`, returns 2. An expression that could not match would report
`matches=0` against an archive that shipped the whole sample.

## 2. `test/aurora_meter/packaging_test.exs`

Six tests in the library's own suite, so the assertion travels with the library
rather than living in a script somebody has to remember to run.

| Test | What it holds |
|---|---|
| "the file list is an explicit allow list" | the floor: the list is non-empty and contains `lib` and `mix.exs`, so an empty or missing list cannot make the rest pass |
| "no entry ships the sample application" | no entry contains `examples` |
| "no entry ships the historical demo project" | no entry contains `demo` |
| "no entry ships the test suite, the docs or priv" | no entry is `test`, `docs`, `priv`, `doc`, `cover`, `_build` or `deps` |
| "the scan can see a forbidden entry" | the control: the same filters over `@files ++ ["examples", "demo", "test"]` return exactly those three |
| "the sample exists on disk and is outside the archive" | **both halves**: `examples/aurora_meter_example_ai` exists, so the exclusion is not vacuous, and nothing named like it is under `lib/` |

```
$ mix test test/aurora_meter/packaging_test.exs --seed 0
Result: 6 passed
```

The last row matters more than it looks. Four of these tests are negatives over
one list. If the sample did not exist, all four would pass and none of them would
be guarding anything.

## 3. `.gitignore`

The sample carries its own `.gitignore` from `mix phx.new`, which is what a
reader extracting this directory into its own repository gets. The package root's
`.gitignore` repeats the same paths under `/examples/*/`, so that a `git add -A`
run from the package root cannot commit them whichever directory it is run from:

```
/examples/*/_build/
/examples/*/deps/
/examples/*/cover/
/examples/*/doc/
/examples/*/.elixir_ls/
/examples/*/.fetch
/examples/*/tmp/
/examples/*/.env
/examples/*/priv/static/assets/
/examples/*/priv/static/cache_manifest.json
/examples/*/assets/node_modules/
/examples/*/*.tar
```

A previous unit in this programme left 2,909 untracked files in a package root
and another left 153 stray HTML files, and both were caught at the commit gate
rather than by their authors. The sample's `deps/` alone is 51 packages.

The CI job has a step for the same thing:

```yaml
- name: Nothing in the sample tree is untracked
  run: |
    untracked=$(git status --porcelain --untracked-files=all -- examples/ | wc -l)
    if [ "$untracked" -ne 0 ]; then ... exit 1; fi
```

## 4. Extraction later

09.05 wants the sample extractable to its own public repository without blocking
V1. It is: a `git filter-repo` of one directory, plus changing

```elixir
{:aurora_meter, path: "../.."}
```

to

```elixir
{:aurora_meter, "~> 1.0"}
```

and nothing else. `test/aurora_meter_example_ai/profile_test.exs` asserts the
path form is the one in the tree today, so a change to it is visible.

## 5. One thing that is untidy and is not this unit's

`aurora_meter-0.5.0.tar` is sitting untracked in the package root from an
earlier `mix hex.build`. The package's `.gitignore` carries `*.ez` but not
`*.tar`. It predates this unit and is recorded in `09c-library-findings.md`
section 8 rather than moved, because moving another unit's output is how X326
happened.
