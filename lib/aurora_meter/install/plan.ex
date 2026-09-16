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

  # -- the two packages ------------------------------------------------------

  defp spec(:core) do
    %{
      module: AuroraMeter.Migration,
      call: "AuroraMeter.Migration",
      label: "Aurora Meter",
      suffix: "aurora_meter",
      module_suffix: "AuroraMeter",
      # Core's `Migration.down/1` raises `DataLossError` unless the flag is
      # passed for a version whose `down` destroys a commercial fact.
      data_loss: true
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
      # Pro's `Migration.down/1` does not guard data loss yet: that guard and
      # the flag that satisfies it are build unit 11b's. Emitting
      # `confirm_data_loss: true` here would put an option in a host's committed
      # file that nothing reads, which reads as a guarantee and is not one.
      data_loss: false
    }
  end

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

  defp fresh_down(%{call: call, data_loss: true}, latest),
    do: "#{call}.down(version: #{latest}, to: 1, confirm_data_loss: true)"

  defp fresh_down(%{call: call, data_loss: false}, latest),
    do: "#{call}.down(version: #{latest}, to: 1)"

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
      up: "#{package.call}.up(from: #{first}, version: #{last})",
      down: down(package, first, last),
      attributes: attributes(concurrent?),
      range: range
    }
  end

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

  defp down(%{call: call, data_loss: true, module: module}, first, last) do
    if Enum.any?(first..last//1, &(&1 in module.data_loss_versions())) do
      "#{call}.down(version: #{last}, to: #{first}, confirm_data_loss: true)"
    else
      "#{call}.down(version: #{last}, to: #{first})"
    end
  end

  defp down(%{call: call, data_loss: false}, first, last),
    do: "#{call}.down(version: #{last}, to: #{first})"

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
