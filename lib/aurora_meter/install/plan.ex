defmodule AuroraMeter.Install.Plan do
  @moduledoc false
  # **Internal.** The host migration files an install or an upgrade has to
  # become, for both packages.
  #
  # Four callers want the same answer: `mix aurora_meter.install`,
  # `mix aurora_meter.gen.migration`, `mix aurora_meter_pro.install` and
  # `mix aurora_meter_pro.gen.migration`. Before this module the installers
  # wrote an unbounded `AuroraMeter.Migration.up()` and the generators wrote
  # bounded ranges, so two supported ways of installing the same package
  # produced two different files and only one of them was reproducible
  # (`open-findings.md` S1). They read one plan now, so they cannot drift.
  #
  # Nothing here touches the filesystem: it returns descriptors and the callers
  # write them, because Igniter and `Mix.Generator` write files in quite
  # different ways.

  @typedoc "One host migration file, as source fragments."
  @type file :: %{
          suffix: String.t(),
          module_suffix: String.t(),
          up: String.t(),
          down: String.t(),
          attributes: String.t(),
          range: %{from: pos_integer(), to: pos_integer(), concurrent: boolean()}
        }

  @doc """
  The files a fresh install or an upgrade from `:from` has to write.

  Options:

    * `:package` - `:core` (default) or `:pro`
    * `:from` - `nil` (default) for a fresh install, or the first version of an
      upgrade
    * `:validate_checks` - when `false`, the file covering core version 8 is
      emitted with `validate_checks: false`. That is the remedy
      `mix aurora_meter.events.backfill` prints for a database holding rows the
      V1 contract would refuse: a non-positive quantity or metadata above 16
      KiB, neither of which `AuroraMeter.track/4` ever rejected. Without it the
      operator is told to run version 8 with an option their generated
      migration has no way to carry, and the only route is to hand-edit a
      generated file (build unit 11a, `open-findings.md` X428). Omitted from the
      generated body when not given, so the default stays `true` and a host that
      never needed it has nothing extra in its committed migration.

  A fresh install is one file whatever the version list looks like: the database
  is empty, so the concurrent version can build its index inside the transaction
  like any other statement, and its `down` carries `confirm_data_loss: true`
  because undoing an install is exactly the case where dropping the tables is
  what was asked for.

  An upgrade is one file per contiguous run of ordinary versions plus one file
  per concurrent version, in the order they have to run.
  """
  @spec files(keyword()) :: [file()]
  def files(opts \\ []) do
    package = spec(Keyword.get(opts, :package, :core))
    package = Map.put(package, :validate_checks, Keyword.get(opts, :validate_checks))

    case Keyword.get(opts, :from) do
      nil -> [fresh(package)]
      from -> upgrade(package, from)
    end
  end

  @doc """
  The latest version of `package`, so a caller can report it without knowing
  which migration module to ask.
  """
  @spec latest_version(:core | :pro) :: pos_integer()
  def latest_version(package), do: spec(package).module.latest_version()

  @doc """
  Raises `Mix.Error` when `from` is above the latest version of `package`.

  A generator that silently produced nothing for `--from 99` would leave the
  operator believing an upgrade had been generated.
  """
  @spec validate_from!(:core | :pro, pos_integer()) :: :ok
  def validate_from!(package, from) do
    %{module: module, label: label} = spec(package)
    latest = module.latest_version()

    if from > latest do
      Mix.raise(
        "--from #{from} is above the latest #{label} schema version (#{latest}). " <>
          "Nothing to generate."
      )
    end

    :ok
  end

  @doc """
  The version an upgrade has to start from, read from the schema marker in the
  database, and the file that already covers it if there is one.

  Returns `{:ok, from}`, `:up_to_date`, or raises `Mix.Error` with what to do
  instead. `repo` must already be started.

  The marker is `aurora_meter_checkpoints["schema:core"]` and
  `["schema:pro"]`, written by `Migration.up/1` at the end of each successful
  version from core 7 and Pro 10 (`schema-migration-map.md` section 3). Its
  absence is not "version 0": it means the database has not reached the version
  that creates the table, and this refuses rather than guessing, because
  guessing low re-runs migrations that have already run and guessing high skips
  ones that have not.
  """
  @spec detect_from(:core | :pro, module()) :: {:ok, pos_integer()} | :up_to_date
  def detect_from(package, repo) do
    %{module: module, label: label, marker: marker, marker_from: marker_from} = spec(package)
    latest = module.latest_version()

    case installed_version(repo, marker) do
      {:ok, installed} when installed >= latest ->
        :up_to_date

      {:ok, installed} ->
        {:ok, installed + 1}

      :no_marker ->
        Mix.raise(
          "--upgrade cannot tell which #{label} schema version this database is on: " <>
            "aurora_meter_checkpoints has no \"#{marker}\" row. That row is written from " <>
            "schema version #{marker_from} onwards, so its absence means the database has " <>
            "not reached version #{marker_from} yet. Read your priv/repo/migrations to see " <>
            "which version you are on and pass it: `--from <version + 1>`. " <>
            "#{first_upgrade_hint(package)}"
        )

      :no_table ->
        Mix.raise(
          "--upgrade cannot tell which #{label} schema version this database is on: " <>
            "the aurora_meter_checkpoints table does not exist, which means the database " <>
            "is below core schema version 7. Read your priv/repo/migrations and pass " <>
            "`--from <version + 1>`. #{first_upgrade_hint(package)}"
        )

      {:error, reason} ->
        Mix.raise(
          "--upgrade could not read the #{label} schema marker: #{inspect(reason)}. " <>
            "Pass `--from <version>` instead."
        )
    end
  end

  @doc """
  Raises when a migration in `path` already runs a version in `range`.

  Generating a second file for a version that is already in the host's
  migrations directory produces a history that applies it twice: harmless for
  an idempotent version and a `duplicate_column` for one that is not, and in
  both cases it is not what the operator asked for.
  """
  @spec refuse_existing!(:core | :pro, String.t(), Range.t()) :: :ok
  def refuse_existing!(package, path, range) do
    %{call: call, label: label} = spec(package)
    pattern = ~r/#{Regex.escape(call)}\.up\(from: (\d+), version: (\d+)\)/

    clashes =
      path
      |> Path.join("*.exs")
      |> Path.wildcard()
      |> Enum.flat_map(fn file ->
        covered =
          pattern
          |> Regex.scan(File.read!(file))
          |> Enum.flat_map(fn [_, from, to] ->
            Enum.to_list(String.to_integer(from)..String.to_integer(to)//1)
          end)

        case Enum.filter(covered, &(&1 in range)) do
          [] -> []
          versions -> [{Path.basename(file), versions}]
        end
      end)

    if clashes != [] do
      detail =
        Enum.map_join(clashes, "; ", fn {file, versions} ->
          "#{file} already runs #{label} #{Enum.join(versions, ", ")}"
        end)

      Mix.raise(
        "refusing to generate a migration for a version this repository already has: " <>
          detail <>
          ". Delete the generated file you do not want, or pass `--from` with " <>
          "a version above the ones already covered."
      )
    end

    :ok
  end

  defp first_upgrade_hint(:core),
    do: "A database at core schema version 6 (the 0.4.0 release) upgrades with `--from 7`."

  defp first_upgrade_hint(:pro),
    do: "A database at Pro schema version 9 (the 0.3.0 release) upgrades with `--from 10`."

  defp installed_version(repo, marker) do
    %{rows: rows} =
      repo.query!(
        "SELECT (cursor->>'version')::integer FROM aurora_meter_checkpoints WHERE name = $1",
        [marker]
      )

    case rows do
      [[version]] when is_integer(version) -> {:ok, version}
      _ -> :no_marker
    end
  rescue
    error in Postgrex.Error ->
      if error.postgres[:code] == :undefined_table, do: :no_table, else: {:error, error}

    error ->
      {:error, error}
  end

  # -- the two packages ------------------------------------------------------

  defp spec(:core) do
    %{
      module: AuroraMeter.Migration,
      call: "AuroraMeter.Migration",
      label: "Aurora Meter",
      suffix: "aurora_meter",
      module_suffix: "AuroraMeter",
      marker: "schema:core",
      marker_from: 7
    }
  end

  defp spec(:pro) do
    %{
      # Built rather than written, so core carries no static reference to a
      # module that only exists in the other package. Core never depends on Pro
      # (`free-pro-boundary.md`), and a literal alias here would be read by a
      # reader as one even though the compiler treats it as an atom.
      module: Module.concat([:AuroraMeter, :Pro, :Migration]),
      call: "AuroraMeter.Pro.Migration",
      label: "Aurora Meter Pro",
      suffix: "aurora_meter_pro",
      module_suffix: "AuroraMeterPro",
      marker: "schema:pro",
      marker_from: 10
    }
  end

  # **Both packages guard data loss, so neither spec carries a flag saying
  # whether it does.** Until build unit 11a Pro had no `data_loss_versions/0`
  # and no guard, so this module carried a `data_loss:` boolean and two clauses
  # each for `fresh_down/2` and `down/3`: one that emitted `confirm_data_loss`
  # and one that did not, because emitting the option for a runtime that never
  # read it would have been a guarantee that was not one (`open-findings.md`
  # X369). Pro has both now, the false branches became unreachable, and dialyzer
  # said so. They are gone rather than left as a shape somebody might read as an
  # option that still exists.
  #
  # Whether a particular file carries the flag is decided per range, by asking
  # the package's own `data_loss_versions/0`, which is the only question that
  # was ever really being asked.

  # -- a fresh install -------------------------------------------------------

  defp fresh(package) do
    latest = package.module.latest_version()

    %{
      suffix: "add_#{package.suffix}",
      module_suffix: "Add#{package.module_suffix}",
      up: fresh_up(package, latest),
      down: fresh_down(package, latest),
      attributes: "",
      range: %{from: 1, to: latest, concurrent: false}
    }
  end

  defp fresh_up(%{call: call, module: module} = _package, latest) do
    if module.concurrent_versions() == [] do
      "#{call}.up(from: 1, version: #{latest})"
    else
      "#{call}.up(from: 1, version: #{latest}, concurrently: false)"
    end
  end

  # Undoing an install is exactly the case where destroying the tables is what
  # was asked for, and version 1 is on both packages' lists anyway.
  defp fresh_down(%{call: call}, latest),
    do: "#{call}.down(version: #{latest}, to: 1, confirm_data_loss: true)"

  # -- an upgrade ------------------------------------------------------------

  defp upgrade(package, from) do
    # `module` is a runtime value, so this is a dynamic dispatch and the compiler
    # resolves nothing: core carries no compile-time reference to the Pro
    # migration module, which is the point (`free-pro-boundary.md`).
    module = package.module

    module.ranges(from: from) |> Enum.map(&file(package, &1))
  end

  defp file(package, %{from: first, to: last, concurrent: concurrent?} = range) do
    %{
      suffix: suffix(package, first, last, concurrent?),
      module_suffix: module_suffix(package, first, last, concurrent?),
      up:
        "#{package.call}.up(from: #{first}, version: #{last}#{up_options(package, first, last)})",
      down: down(package, first, last),
      attributes: attributes(concurrent?),
      range: range
    }
  end

  # `validate_checks:` belongs to core version 8 and to nothing else, so it is
  # emitted only on the file that covers it. Emitting it on every file would put
  # an option in a host's committed migration that the version it names does not
  # read, which is the false-guarantee shape Pro's `confirm_data_loss` used to
  # have (`open-findings.md` X369).
  defp up_options(%{validate_checks: false, module: AuroraMeter.Migration}, first, last)
       when first <= 8 and last >= 8,
       do: ", validate_checks: false"

  defp up_options(_package, _first, _last), do: ""

  defp suffix(package, version, version, true),
    do: "upgrade_#{package.suffix}_v#{version}_concurrent"

  defp suffix(package, version, version, false), do: "upgrade_#{package.suffix}_v#{version}"

  defp suffix(package, first, last, false), do: "upgrade_#{package.suffix}_v#{first}_to_v#{last}"

  defp module_suffix(package, version, version, true),
    do: "Upgrade#{package.module_suffix}V#{version}Concurrent"

  defp module_suffix(package, version, version, false),
    do: "Upgrade#{package.module_suffix}V#{version}"

  defp module_suffix(package, first, last, false),
    do: "Upgrade#{package.module_suffix}V#{first}ToV#{last}"

  defp down(%{call: call, module: module}, first, last) do
    if Enum.any?(first..last//1, &(&1 in module.data_loss_versions())) do
      "#{call}.down(version: #{last}, to: #{first}, confirm_data_loss: true)"
    else
      "#{call}.down(version: #{last}, to: #{first})"
    end
  end

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
end
