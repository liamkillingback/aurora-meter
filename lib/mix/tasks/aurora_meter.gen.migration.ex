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
  """

  use Mix.Task

  import Mix.Generator

  alias AuroraMeter.Install.Plan

  @switches [from: :integer]

  @impl Mix.Task
  @spec run([String.t()]) :: :ok
  def run(args) do
    repos = Mix.Ecto.parse_repo(args)
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: @switches)

    if repos == [] do
      Mix.raise("no ecto repo found: pass one with `-r MyApp.Repo` or set `:ecto_repos`.")
    end

    Enum.each(repos, fn repo ->
      Mix.Ecto.ensure_repo(repo, args)
      gen_for_repo(repo, opts[:from])
    end)
  end

  defp gen_for_repo(repo, from) do
    path = Ecto.Migrator.migrations_path(repo)
    create_directory(path)

    from
    |> files()
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
  defp files(from) do
    if from, do: Plan.validate_from!(:core, from)

    Plan.files(package: :core, from: from)
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
