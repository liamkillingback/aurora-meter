defmodule Mix.Tasks.AuroraMeter.Gen.Migration do
  @shortdoc "Generates the Aurora Meter database migration"

  @moduledoc """
  Generates a migration that installs the Aurora Meter tables into the host app.

      mix aurora_meter.gen.migration -r MyApp.Repo

  The generated migration delegates to `AuroraMeter.Migration`, so future schema
  changes ship as new versions of that module rather than as edits to your
  migration file. To upgrade an existing install to a newer schema version:

      mix aurora_meter.gen.migration -r MyApp.Repo --from 3

  which generates a migration running only versions `3..latest` (version 3 adds
  the prepaid credit ledger tables; `--from 2` on an 0.1 install also adds the
  usage history table). See `AuroraMeter.Migration` for the version list.
  """

  use Mix.Task

  import Mix.Generator

  @switches [from: :integer]

  @impl Mix.Task
  def run(args) do
    repos = Mix.Ecto.parse_repo(args)
    {opts, _rest, _invalid} = OptionParser.parse(args, switches: @switches)

    if repos == [] do
      Mix.raise("no ecto repo found — pass one with `-r MyApp.Repo` or set `:ecto_repos`.")
    end

    Enum.each(repos, fn repo ->
      Mix.Ecto.ensure_repo(repo, args)
      gen_for_repo(repo, opts[:from])
    end)
  end

  defp gen_for_repo(repo, from) do
    path = Ecto.Migrator.migrations_path(repo)
    create_directory(path)

    {suffix, module_suffix, up_call, down_call} =
      case from do
        nil ->
          {"add_aurora_meter", "AddAuroraMeter", "AuroraMeter.Migration.up()",
           "AuroraMeter.Migration.down()"}

        n ->
          {"upgrade_aurora_meter_v#{n}", "UpgradeAuroraMeterV#{n}",
           "AuroraMeter.Migration.up(from: #{n})", "AuroraMeter.Migration.down(to: #{n})"}
      end

    file = Path.join(path, "#{timestamp()}_#{suffix}.exs")
    module = Module.concat([repo, Migrations, module_suffix])
    create_file(file, migration_template(module: module, up: up_call, down: down_call))
  end

  defp timestamp do
    {{y, m, d}, {hh, mm, ss}} = :calendar.universal_time()
    "#{y}#{pad(m)}#{pad(d)}#{pad(hh)}#{pad(mm)}#{pad(ss)}"
  end

  defp pad(int) when int < 10, do: "0#{int}"
  defp pad(int), do: "#{int}"

  embed_template(:migration, """
  defmodule <%= inspect @module %> do
    use Ecto.Migration

    def up, do: <%= @up %>
    def down, do: <%= @down %>
  end
  """)
end
