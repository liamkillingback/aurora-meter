defmodule Mix.Tasks.AuroraMeter.Gen.Migration do
  @shortdoc "Generates the Aurora Meter database migration"

  @moduledoc """
  Generates a migration that installs the Aurora Meter tables into the host app.

      mix aurora_meter.gen.migration -r MyApp.Repo

  The generated migration delegates to `AuroraMeter.Migration`, so future schema
  changes ship as new versions of that module rather than as edits to your
  migration file. To upgrade an existing install to a newer schema version:

      mix aurora_meter.gen.migration -r MyApp.Repo --from 7

  which generates migrations running versions `7..latest`. See
  `AuroraMeter.Migration` for the version list.

  ## `--upgrade`, which reads the version rather than being told it

      mix aurora_meter.gen.migration -r MyApp.Repo --upgrade

  `--upgrade` starts the repo, reads the installed schema version from
  `aurora_meter_checkpoints["schema:core"]` and generates from the next one.
  It refuses, with what to do instead, when the marker is absent: that row
  arrives with version 7, so its absence means the database has not reached
  version 7 and the version has to come from the host's own migrations
  directory. It does not guess, because guessing low re-runs migrations that
  have already run and guessing high skips ones that have not.

  It also refuses when a migration already in `priv/repo/migrations` covers a
  version in the range, naming the file, so running the generator twice cannot
  produce a history that applies the same version twice.

  ## Two things the generated files do on purpose

  **The version range is pinned at both ends.** A generated `up(from: 7)` would
  run to whatever the latest version is on the day it first applies, so a
  database created today and one created after the next release would run the
  same migration file and end up with different schemas. Every generated body
  names both ends.

  **A concurrent version gets a file of its own.** Core schema version 8
  creates a unique index `CONCURRENTLY`, which Postgres refuses inside a
  transaction block, so its file carries `@disable_ddl_transaction true` and
  `@disable_migration_lock true` and runs that version and nothing else. A
  range that spans one is therefore emitted as several files: one per
  contiguous run of ordinary versions, and one per concurrent version, in
  order.

  A fresh install is the exception: it passes `concurrently: false` and builds
  the index inside the transaction, because there are no rows to lock. Its
  `down` carries `confirm_data_loss: true`, because undoing an install is
  exactly the case where destroying the tables is what was asked for. An
  upgrade file's `down` carries it only when the range it covers holds a
  version whose `down` destroys a commercial fact.

  ## `--no-validate-checks`, for a database with rows the V1 contract refuses

      mix aurora_meter.gen.migration -r MyApp.Repo --from 7 --no-validate-checks

  `AuroraMeter.track/4` never rejected a non-positive quantity and never bounded
  metadata, so a database written by 0.4.x can hold rows that core schema
  version 8's constraints refuse. `mix aurora_meter.events.backfill` counts them
  and prints the remedy: run version 8 with `validate_checks: false`, which
  leaves those two constraints `NOT VALID` (still enforced on every new row, and
  recorded in the schema marker) instead of proving them against history.

  Until build unit 11a the generated file had no way to carry that option, so
  the only route from the backfill's advice to a working upgrade was to
  hand-edit a generated migration (`open-findings.md` X428). The flag emits it
  on the file covering version 8 and on no other file. Without the flag nothing
  is emitted and the default, `true`, stands.
  """

  use Mix.Task

  import Mix.Generator

  alias AuroraMeter.Install.Plan

  @switches [from: :integer, validate_checks: :boolean, upgrade: :boolean]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    repos = Mix.Ecto.parse_repo(args)
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: @switches)

    if repos == [] do
      Mix.raise("no ecto repo found: pass one with `-r MyApp.Repo` or set `:ecto_repos`.")
    end

    if opts[:upgrade] && opts[:from] do
      Mix.raise(
        "--upgrade and --from say the same thing two different ways. --upgrade reads the " <>
          "installed version from the database; --from states it. Pass one."
      )
    end

    Enum.each(repos, fn repo ->
      Mix.Ecto.ensure_repo(repo, args)
      gen_for_repo(repo, opts)
    end)
  end

  defp gen_for_repo(repo, opts) do
    case resolve_from(repo, opts) do
      :up_to_date -> :ok
      from -> write_files(repo, from, opts[:validate_checks])
    end
  end

  # `--upgrade` needs the database, so the repo is started for the read and
  # stopped again. Everything else about this task is offline.
  defp resolve_from(repo, opts) do
    if opts[:upgrade], do: detected_from(repo), else: opts[:from]
  end

  # `with_repo/3` starts the repo and the applications it needs, runs the read,
  # and stops both. It is what `mix ecto.migrate` itself uses, so a host that
  # can migrate can run this.
  defp detected_from(repo) do
    path = Ecto.Migrator.migrations_path(repo)

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(repo, &announce(Plan.detect_from(:core, &1), path))

    result
  end

  defp announce(:up_to_date, _path) do
    Mix.shell().info([
      :yellow,
      "this database is already on Aurora Meter schema version " <>
        "#{Plan.latest_version(:core)}. Nothing to generate."
    ])

    :up_to_date
  end

  defp announce({:ok, from}, path) do
    latest = Plan.latest_version(:core)

    Mix.shell().info(
      "detected Aurora Meter schema version #{from - 1}; generating #{from} to #{latest}"
    )

    Plan.refuse_existing!(:core, path, from..latest//1)
    from
  end

  defp write_files(repo, from, validate_checks) do
    path = Ecto.Migrator.migrations_path(repo)
    create_directory(path)

    from
    |> files(validate_checks)
    |> Enum.with_index()
    |> Enum.each(fn {file, index} ->
      module = Module.concat([repo, Migrations, file.module_suffix])

      Path.join(path, "#{timestamp(index)}_#{file.suffix}.exs")
      |> create_file(
        migration_template(
          module: module,
          up: file.up,
          down: file.down,
          attributes: file.attributes
        )
      )
    end)
  end

  # Both the list of files and their bodies come from
  # `AuroraMeter.Install.Plan`, which `mix aurora_meter.install` reads too, so
  # the two supported ways of installing this package cannot produce two
  # different migrations (`open-findings.md` S1).
  defp files(from, validate_checks) do
    if from, do: Plan.validate_from!(:core, from)

    Plan.files(package: :core, from: from, validate_checks: validate_checks)
  end

  # One second apart per file, so several generated files keep the order the
  # versions have to run in.
  defp timestamp(offset) do
    {{y, m, d}, {hh, mm, ss}} =
      :calendar.universal_time()
      |> :calendar.datetime_to_gregorian_seconds()
      |> Kernel.+(offset)
      |> :calendar.gregorian_seconds_to_datetime()

    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(int) when int < 10, do: "0#{int}"
  defp pad(int), do: "#{int}"

  embed_template(:migration, """
  defmodule <%= inspect @module %> do
    use Ecto.Migration
  <%= @attributes %>
    def up, do: <%= @up %>
    def down, do: <%= @down %>
  end
  """)
end
