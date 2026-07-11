defmodule Mix.Tasks.AuroraMeter.Gen.Migration do
  @shortdoc "Generates the Aurora Meter database migration"

  @moduledoc """
  Generates a migration that installs the Aurora Meter tables into the host app.

      mix aurora_meter.gen.migration -r MyApp.Repo

  The generated migration delegates to `AuroraMeter.Migration`, so future schema
  changes ship as new versions of that module rather than as edits to your
  migration file.
  """

  use Mix.Task

  import Mix.Generator

  @impl Mix.Task
  def run(args) do
    repos = Mix.Ecto.parse_repo(args)

    if repos == [] do
      Mix.raise("no ecto repo found — pass one with `-r MyApp.Repo` or set `:ecto_repos`.")
    end

    Enum.each(repos, &gen_for_repo/1)
  end

  defp gen_for_repo(repo) do
    path = Ecto.Migrator.migrations_path(repo)
    create_directory(path)
    file = Path.join(path, "#{timestamp()}_add_aurora_meter.exs")
    module = Module.concat([repo, Migrations, AddAuroraMeter])
    create_file(file, migration_template(module: module))
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

    def up, do: AuroraMeter.Migration.up()
    def down, do: AuroraMeter.Migration.down()
  end
  """)
end
