defmodule AuroraMeterExampleAi.Repo.Migrations.AddOban do
  @moduledoc """
  Oban's own tables. **Pro profile only.**

  ## Why this lives in its own migrations path

  It cannot go in `priv/repo/migrations` with the rest. That directory is run
  by every `mix ecto.migrate` in both profiles, Ecto compiles each file it
  finds there, and `Oban.Migration` does not exist in a core-profile build:
  the core profile has no Oban dependency at all. A reader without a licence
  would get a compile error from a migration, which is a spectacularly
  confusing place to meet a missing dependency.

  Guarding the body with `Code.ensure_loaded?/1` would compile, and it would be
  worse. The migration would be recorded in `schema_migrations` in the core
  profile with none of the tables created, and a later opt-in would find the
  version already applied and the tables missing. The error would then arrive
  at boot, in production, as "the oban_jobs table does not exist".

  So the two profiles have two migration paths, and `mix.exs`'s aliases run the
  second one only when `AURORA_SAMPLE_PRO=1`:

      mix ecto.migrate
      mix ecto.migrate --migrations-path priv/repo/pro_migrations

  Both write into the same `schema_migrations` table keyed by version, so the
  history is one history and the ordering is by timestamp as usual.
  """
  use Ecto.Migration

  # 14 is the version this Oban requires, and it is pinned rather than left to
  # `Oban.Migration.up()`'s default for the reason every generated migration in
  # this repository pins both ends: a migration whose range is "whatever is
  # current" gives two databases different schemas from the same committed
  # file. Oban refuses to start on a version below the one it needs and names
  # both numbers, which is how this one was found.
  def up, do: Oban.Migration.up(version: 14)

  # Version 1 is Oban's own floor: it leaves the tables in the shape a fresh
  # install would have had before any of them existed.
  def down, do: Oban.Migration.down(version: 1)
end
