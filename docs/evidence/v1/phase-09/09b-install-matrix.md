# 09b: the installer, option by option, and what a second run does

Build unit 09b, task 09.04, decision D04. Captured 2026-09-16 (UTC).

Two kinds of run, because they answer different questions and neither is
sufficient on its own:

- **in suite**, `test/mix/tasks/install_test.exs`, 42 tests through
  `Igniter.Test`. It composes the task against a source tree held in memory and
  never writes a file, which is what makes the negative assertions ("creates no
  file at all") exact;
- **on disk**, `tmp/v1/09b-host.sh`, a real scratch Mix project with a real
  `mix deps.get`, the real task and real files, sha256 per file before and
  after. Raw output in `tmp/v1/09b/host-run.txt` and `tmp/v1/09b/host/`.

The on-disk run exists because `Igniter.Test` proves what the task *computes*
and not what it *writes*, and criterion 1 is about bytes on a host's disk.

## What the first run writes

`mix aurora_meter.install --repo Demo.Repo --oban --events-source tokens:events`
in a project that had `config/config.exs` with one line in it:

| File | Created | What it carries |
|---|---|---|
| `config/config.exs` | updated | `config :aurora_meter` with `repo`, `pubsub`, `plans`, `undeclared_feature_policy: :deny`, `feature_sources: %{tokens: :events}`; `config :demo, Oban` with the `aurora_meter` queue and the five cron entries |
| `lib/demo/application.ex` | updated | `AuroraMeter` in the child list, after the repo; `AuroraMeter.Oban.validate!(otp_app: :demo)` before it |
| `lib/demo/plans.ex` | created | `use AuroraMeter.Plans` with `:free` and `:pro` |
| `priv/repo/migrations/<ts>_add_aurora_meter.exs` | created | the bounded body (below) |

The generated `config :aurora_meter` block, verbatim:

    config :aurora_meter,
      repo: Demo.Repo,
      pubsub: Demo.PubSub,
      plans: Demo.Plans,
      undeclared_feature_policy: :deny,
      feature_sources: %{tokens: :events}

The generated migration, verbatim:

    defmodule Demo.Repo.Migrations.AddAuroraMeter do
      use Ecto.Migration

      def up, do: AuroraMeter.Migration.up(from: 1, version: 10, concurrently: false)
      def down, do: AuroraMeter.Migration.down(version: 10, to: 1, confirm_data_loss: true)
    end

Until this unit that body was `AuroraMeter.Migration.up()`. See
`09b-generated-migrations.md`.

## The option matrix

| Command | Files created | Config written | Second run |
|---|---|---|---|
| `--repo Demo.Repo` | config, application, plans, one migration | the three module keys plus `undeclared_feature_policy: :deny` | no change to any file |
| `--repo Demo.Repo --feature-policy warn` | same | `undeclared_feature_policy: :warn`, and no `:deny` anywhere | no change |
| `--repo Demo.Repo --feature-policy allow \| deny \| raise` | same | the value asked for, each one asserted | no change |
| `--repo Demo.Repo --feature-policy bogus` | **none** | none | n/a: one issue, no change at all |
| `--repo Demo.Repo --events-source tokens:events` | same | `feature_sources: %{tokens: :events}` | no change |
| `--events-source tokens:events --events-source requests:buffered` | same | both pairs in one map | no change |
| (no `--events-source`) | same | **no `feature_sources` key at all** | no change |
| `--events-source tokens:bogus` | **none** | none | n/a |
| `--events-source tokens` (malformed) | **none** | none | n/a |
| `--events-source Tokens.Bad:events` | **none** | none | n/a |
| `--events-source tokens:events --events-source tokens:buffered` | **none** | none | n/a |
| `--repo Demo.Repo --oban` | same | the `aurora_meter` queue, the Cron plugin, five entries, and the `validate!/1` call once | no change |
| `--check-support` | **none** | none | n/a: it writes nothing by construction |
| `--dry-run` (Igniter's global switch) | **none** | none | n/a |

Every "none" row is asserted as `assert_unchanged(igniter)` **plus** the issue
text, not as the absence of one file. The task parses and validates before it
touches anything, so a refusal leaves an igniter carrying one issue and no
change, and Igniter writes nothing when there are issues
(`deps/igniter/lib/igniter.ex:1166`). On disk: a refused run left all five files
byte identical.

The refusal messages name the valid values and end "Nothing was written." For
example:

    * --feature-policy bogus is not one of allow, warn, deny, raise.

      deny   refuse a feature no plan declares (the default for a new install)
      raise  the same, as an exception rather than a refusal
      warn   allow it and log, which is the upgrade path for an existing install
      allow  allow it silently, which is how Aurora Meter behaved before 1.0

      Nothing was written.

**One thing the refusal does not do: it does not exit non-zero.** Igniter
displays issues and `do_or_dry_run/2` returns `:issues` without setting an exit
status, so `mix aurora_meter.install --feature-policy bogus` prints the refusal,
writes nothing, and exits 0. Measured on the host project. That is Igniter's
behaviour and it is shared by every Igniter task in both packages, including
Pro's refusal to schedule two expiry workers (05c). It is recorded here rather
than worked around, because the fix is a framework-level decision. It is also why
`--check-support` raises rather than adding an issue: see
`09b-support-matrix.md`.

## The second run, on disk, byte identical

`mix aurora_meter.install --repo Demo.Repo --oban --events-source tokens:events`
twice, with the first run **applied** to the filesystem before the second starts.
sha256 per file, from `tmp/v1/09b/host/snap.1` and `snap.2`:

| File | sha256 after run 1 and after run 2 |
|---|---|
| `config/config.exs` | `344fa8a83c5a7beb18e80b75dadee7e46203a52b0fc4772563ccb0550e453659` |
| `lib/demo/application.ex` | `af3a531e7c1ca408c460165a654dbf5785b278b68a03a7f5f5f4a6452677dd2a` |
| `lib/demo/plans.ex` | `e2e18ba52f496c5c8cbcc69cc8f05943ee10e35931c4577e477490349878a370` |
| `lib/demo/repo.ex` | `76345c3e7714bf92bcc3c50d2239a8cc099ca815a120395db7ee640c4e3f42b8` |
| `priv/repo/migrations/<ts>_add_aurora_meter.exs` | `fa7e9466a6101a1e7f0cf3b8fd1e879471d8a1306cab9feb0ed9bf294a0cf4b9` |

`diff` over the two digest listings is empty. In suite the same claim is asserted
three ways: `assert_unchanged/1` on the second composition, an explicit
`source(applied, path) == source(second, path)` per file, and a **third** run,
because a task that is idempotent once can still drift on the next.

## A host that is not pristine

The strongest of these runs, and the one D04 is about. The host's
`config/config.exs` was hand edited between run 2 and run 3 to be everything an
upgrading host actually is: a policy it chose during the 0.5.x transition, a
feature source it tuned to the opposite of what the command line asks for, a
queue concurrency of its own, one of our cron workers on its own schedule, its
own worker beside it, its own plugin, and the `:aurora_meter` keys in a
different order from the one the installer writes.

    config :demo, Oban,
      repo: Demo.Repo,
      queues: [mailers: 10, aurora_meter: 2],
      plugins: [
        Oban.Plugins.Pruner,
        {Oban.Plugins.Cron,
         crontab: [
           {"@daily", Demo.Workers.Nightly},
           {"0 4 * * *", AuroraMeter.Oban.CreditExpiry}
         ]}
      ]

    config :aurora_meter,
      plans: Demo.Plans,
      undeclared_feature_policy: :warn,
      feature_sources: %{tokens: :buffered},
      pubsub: Demo.PubSub,
      repo: Demo.Repo

Then `mix aurora_meter.install --repo Demo.Repo --oban --events-source
tokens:events` again. What survived, and what was added:

| The host's choice | After the run |
|---|---|
| `undeclared_feature_policy: :warn` | **kept**, and reported (below) |
| `feature_sources: %{tokens: :buffered}` | **kept**, and reported, even though `--events-source tokens:events` was passed |
| `queues: [mailers: 10, aurora_meter: 2]` | kept, concurrency and order both |
| `{"0 4 * * *", AuroraMeter.Oban.CreditExpiry}` | kept, on the host's schedule, and no second entry for that worker |
| `{"@daily", Demo.Workers.Nightly}` | kept |
| `Oban.Plugins.Pruner` | kept, and still first in the plugin list |
| the key order in `config :aurora_meter` | kept |
| the four cron entries the host did not have | **added**, and only those four |

`lib/demo/application.ex`, `lib/demo/plans.ex`, `lib/demo/repo.ex` and the
migration were byte identical; `config/config.exs` was the only file that
changed, and the only change in it was the four missing crontab entries.

And it said so, rather than keeping the values silently:

    * config/config.exs already sets :undeclared_feature_policy. It was kept
      exactly as written.

      This key is the one an upgrading host tunes, so the installer only
      ever creates it and never changes it. A fresh install would have been given
      :deny.

      To change it, edit config/config.exs yourself. The upgrade path from an
      existing install is :warn first, then `mix aurora_meter.features` until it
      reports nothing, then :deny.

    * config/config.exs already sets :feature_sources. It was kept exactly as
      written, and %{tokens: :events} was not applied.

An installer that keeps a value silently cannot be told apart from one that
wrote it, and that difference is the whole of D04's upgrade path. When the flag
was passed explicitly the notice says so by name ("You passed --feature-policy
deny, and it was not applied"), which is asserted in suite.

**Which keys overwrite and which do not.** `:repo`, `:pubsub` and `:plans` keep
today's overwrite semantics: the operator passes them on the command line, so
overwriting is what was asked for. `undeclared_feature_policy` and
`feature_sources` use `Igniter.Project.Config.configure_new/6` and are read
before they are written, so the task knows which of the two things it did.

## `--dry-run`

It is **Igniter's own global switch**, not a second one declared here
(`open-findings.md` X192): `Igniter.Mix.Task.Info.global_options/0` declares
`dry_run: :boolean` for every task and `Igniter.do_or_dry_run/2` implements it.
A test asserts both halves of that claim: this task's schema does **not** declare
`dry_run`, and Igniter's global switches **do**.

On disk, `--dry-run` with every option set left every existing file byte
identical and exited 0. Both halves of criterion 6, measured against a real host
project by `tmp/v1/09b-dryrun.sh`:

**It creates no file.** The `find lib config priv -type f` listing is identical
before and after.

**It prints the change set the real run then applies.** The dry run named
`config/config.exs`, `lib/demo/plans.ex` and
`priv/repo/migrations/<ts>_add_aurora_meter.exs`; the real run with the same
arguments created the last two and updated the first. Its printed diff of
`config/config.exs` carries the two lines this unit added to the installer:

     22 + |  undeclared_feature_policy: :deny,
     23 + |  feature_sources: %{tokens: :events}

**One flag combination prints nothing, and it is the one a script would reach
for.** `Igniter.do_or_dry_run/2` calls `display_diff/2`, which is
`if !opts[:yes]`, so `--dry-run --yes` prints the header `Igniter:` and **no
diff at all**. The first attempt at this evidence used `--yes` for
non-interactivity and got an empty change set; the run above drops `--yes` and
closes stdin instead, which works because `--dry-run` returns before the
confirmation prompt is reached. Worth knowing before 09e writes a clean-room
script around it: `--dry-run` alone is the form that shows you anything.

The Igniter-less fallback has no framework to inherit it from, so this unit
implemented `--dry-run` there: it prints each migration file it would generate,
with its full `up` and `down` bodies, and calls no generator. That path also
understands `--feature-policy` and `--events-source` now, because a fallback that
ignored a switch the operator passed would print one configuration while they had
asked for another, and the host would paste the printed one.

## What the installer will not write

Asserted over every source the task produces, with every option set:
`AuroraMeter.Components`, `AuroraMeter.LiveView`, `AuroraMeter.Plug`,
`Phoenix.Component`, `live "`, `aurora_meter_pro` and `AuroraMeter.Pro` appear in
none of them. Invariant I20: an installer that imported the components or added
a route would make LiveView a requirement of installing at all, whatever
`mix.exs` said, and one that mentioned Pro would put a commercial dependency in
a free install.
