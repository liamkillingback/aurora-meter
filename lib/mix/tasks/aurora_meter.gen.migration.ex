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

  alias AuroraMeter.Migration

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

  # A fresh install is one file: there are no rows, so the concurrent version
  # can build its index inside the transaction like any other statement.
  defp files(nil) do
    latest = Migration.latest_version()

    [
      %{
        suffix: "add_aurora_meter",
        module_suffix: "AddAuroraMeter",
        up: "AuroraMeter.Migration.up(from: 1, version: #{latest}, concurrently: false)",
        down: "AuroraMeter.Migration.down(version: #{latest}, to: 1, confirm_data_loss: true)",
        attributes: []
      }
    ]
  end

  defp files(from) do
    latest = Migration.latest_version()

    if from > latest do
      Mix.raise(
        "--from #{from} is above the latest Aurora Meter schema version (#{latest}). " <>
          "Nothing to generate."
      )
    end

    from..latest//1
    |> Enum.to_list()
    |> chunk()
    |> Enum.map(&file/1)
  end

  # Contiguous ordinary versions travel together; each concurrent version
  # travels alone.
  defp chunk(versions) do
    concurrent = Migration.concurrent_versions()

    versions
    |> Enum.chunk_by(&(&1 in concurrent))
    |> Enum.flat_map(fn [head | _] = group ->
      if head in concurrent, do: Enum.map(group, &[&1]), else: [group]
    end)
  end

  defp file(group) do
    first = List.first(group)
    last = List.last(group)
    concurrent? = first in Migration.concurrent_versions()
    loss? = Enum.any?(group, &(&1 in Migration.data_loss_versions()))

    %{
      suffix: suffix(first, last, concurrent?),
      module_suffix: module_suffix(first, last, concurrent?),
      up: "AuroraMeter.Migration.up(from: #{first}, version: #{last})",
      down: down(first, last, loss?),
      attributes: attributes(concurrent?)
    }
  end

  defp suffix(version, version, true), do: "upgrade_aurora_meter_v#{version}_concurrent"
  defp suffix(version, version, false), do: "upgrade_aurora_meter_v#{version}"
  defp suffix(first, last, false), do: "upgrade_aurora_meter_v#{first}_to_v#{last}"

  defp module_suffix(version, version, true), do: "UpgradeAuroraMeterV#{version}Concurrent"
  defp module_suffix(version, version, false), do: "UpgradeAuroraMeterV#{version}"
  defp module_suffix(first, last, false), do: "UpgradeAuroraMeterV#{first}ToV#{last}"

  defp down(first, last, true),
    do: "AuroraMeter.Migration.down(version: #{last}, to: #{first}, confirm_data_loss: true)"

  defp down(first, last, false),
    do: "AuroraMeter.Migration.down(version: #{last}, to: #{first})"

  defp attributes(false), do: ""

  defp attributes(true) do
    """

      # This version creates a unique index CONCURRENTLY, which Postgres refuses
      # inside a transaction block and which cannot hold the Ecto migration lock
      # either. Both attributes are required; without them
      # AuroraMeter.Migration.up/1 raises rather than fail halfway through.
      @disable_ddl_transaction true
      @disable_migration_lock true
    """
    |> String.trim_trailing("\n")
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
