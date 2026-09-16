defmodule Mix.Tasks.AuroraMeter.Features do
  @shortdoc "Lists declared features, and what a configuration references that no plan declares"

  @moduledoc """
  Shows what flipping `:undeclared_feature_policy` to `:deny` would change.

      mix aurora_meter.features
      mix aurora_meter.features --strict          # exit 1 on an undeclared reference or a plan gap
      mix aurora_meter.features --plans MyApp.Plans

  Four sections:

    1. **Declared features per plan**, with the kind of each.
    2. **Features referenced by configuration**: `:durable_features`,
       `:feature_sources` (skipped while the key is absent), and, when an
       `:aurora_meter_pro` application environment is present, its
       `:stripe_meters`. Pro's environment is read by application name, so this
       task names no Pro module and core gains no dependency on Pro.
    3. **Undeclared references**: something the configuration names that no plan
       declares. Almost always a typo.
    4. **Plan gaps**: a feature some plans declare and others do not, with the
       plans that would deny it under `:deny`. This is the section to read
       before the flip, because a gap is exactly what changes behaviour: a
       tenant on a plan in the "would deny" column is answered permissively
       today and refused afterwards.

  ## What it cannot see

  It reads configuration, not source. A feature named only in a call at runtime
  (`AuroraMeter.check(org, :something)`) is invisible here. The runtime answer to
  that is the `declared:` metadata on `[:aurora_meter, :track]` telemetry and
  the one-per-feature log the `:warn` policy emits; run with `:warn` for a while
  before moving to `:deny`.
  """

  use Mix.Task

  alias AuroraMeter.Config

  @switches [strict: :boolean, plans: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)
    Mix.Task.run("app.config")

    report = report(plans: resolve_plans(opts[:plans]))
    Mix.shell().info(render(report))

    if opts[:strict] && not clean?(report) do
      Mix.raise(
        "aurora_meter.features --strict: the configuration references features no plan " <>
          "declares, or declares a feature on some plans and not others. See the sections above."
      )
    end
  end

  @doc false
  @spec report(keyword()) :: map()
  def report(opts \\ []) do
    module = Keyword.get_lazy(opts, :plans, &Config.plans/0)
    core_env = Keyword.get_lazy(opts, :core_env, fn -> Application.get_all_env(:aurora_meter) end)

    pro_env =
      Keyword.get_lazy(opts, :pro_env, fn -> Application.get_all_env(:aurora_meter_pro) end)

    plans = module.__aurora_plans__()
    references = references(core_env, pro_env)
    declared = declared_anywhere(plans)

    %{
      plans_module: module,
      plans: Enum.sort_by(Enum.map(plans, &plan_row/1), &{&1.id, &1.version}),
      references: references,
      undeclared: undeclared(references, declared),
      gaps: gaps(plans)
    }
  end

  @doc false
  @spec clean?(map()) :: boolean()
  def clean?(report), do: report.undeclared == [] and report.gaps == []

  @doc false
  @spec render(map()) :: String.t()
  def render(report) do
    Enum.join(
      [
        "Aurora Meter features, from #{inspect(report.plans_module)}",
        "",
        section("1. Declared features per plan", render_plans(report.plans)),
        section("2. Features referenced by configuration", render_references(report.references)),
        section("3. Undeclared references", render_undeclared(report.undeclared)),
        section("4. Plan gaps", render_gaps(report.gaps))
      ],
      "\n"
    )
  end

  @spec resolve_plans(String.t() | nil) :: module()
  defp resolve_plans(nil), do: Config.plans()
  defp resolve_plans(name), do: Module.concat([name])

  @spec plan_row({{atom(), String.t()}, AuroraMeter.Plan.t()}) :: map()
  defp plan_row({{id, version}, plan}) do
    features =
      plan.features
      |> Enum.map(fn {feature, config} -> {feature, kind(config)} end)
      |> Enum.sort()

    %{id: id, version: version, price: plan.price, features: features}
  end

  @spec references(keyword(), keyword()) :: [map()]
  defp references(core_env, pro_env) do
    [
      {"config :aurora_meter, :durable_features", list_reference(core_env, :durable_features)},
      {"config :aurora_meter, :feature_sources", map_key_reference(core_env, :feature_sources)},
      {"config :aurora_meter_pro, :stripe_meters", map_key_reference(pro_env, :stripe_meters)}
    ]
    |> Enum.reject(fn {_source, features} -> features == :absent end)
    |> Enum.map(fn {source, features} -> %{source: source, features: features} end)
  end

  @spec list_reference(keyword(), atom()) :: [atom()] | :absent
  defp list_reference(env, key) do
    case Keyword.fetch(env, key) do
      {:ok, value} when is_list(value) -> Enum.sort(value)
      _absent_or_wrong_shape -> :absent
    end
  end

  @spec map_key_reference(keyword(), atom()) :: [atom()] | :absent
  defp map_key_reference(env, key) do
    case Keyword.fetch(env, key) do
      {:ok, value} when is_map(value) -> value |> Map.keys() |> Enum.sort()
      _absent_or_wrong_shape -> :absent
    end
  end

  @spec declared_anywhere(map()) :: MapSet.t()
  defp declared_anywhere(plans) do
    plans
    |> Enum.flat_map(fn {_id, plan} -> Map.keys(plan.features) end)
    |> MapSet.new()
  end

  @spec undeclared([map()], MapSet.t()) :: [map()]
  defp undeclared(references, declared) do
    for %{source: source, features: features} <- references,
        feature <- features,
        not MapSet.member?(declared, feature),
        do: %{feature: feature, source: source}
  end

  # Gaps are reported per plan **id**, not per version: a feature declared by
  # any version of a plan is a name the plans module knows, which is what
  # `:undeclared_feature_policy` resolves through. A feature that one version of
  # a plan declares and another does not is a commercial difference between the
  # versions rather than a configuration mistake, so it is not a gap; a version
  # comparison belongs in `AuroraMeter.Plans.versions/1`, not in this lint.
  @spec gaps(map()) :: [map()]
  defp gaps(plans) do
    by_id =
      Enum.reduce(plans, %{}, fn {{id, _version}, plan}, acc ->
        Map.update(acc, id, MapSet.new(Map.keys(plan.features)), fn declared ->
          MapSet.union(declared, MapSet.new(Map.keys(plan.features)))
        end)
      end)

    ids = by_id |> Map.keys() |> Enum.sort()

    plans
    |> declared_anywhere()
    |> Enum.sort()
    |> Enum.map(fn feature ->
      declared_in = Enum.filter(ids, &MapSet.member?(by_id[&1], feature))
      %{feature: feature, declared_in: declared_in, would_deny: ids -- declared_in}
    end)
    |> Enum.reject(&(&1.would_deny == []))
  end

  @spec kind(AuroraMeter.Plan.feature_config()) :: String.t()
  defp kind({:limit, n, :hard}), do: "hard limit, #{n}"
  defp kind({:metered, included, unit_price}), do: "metered, #{included} included, #{unit_price}"
  defp kind({:counter}), do: "counter"
  defp kind({:feature, true}), do: "feature, granted"
  defp kind({:feature, false}), do: "feature, denied"
  defp kind({:feature, value}), do: "feature value, #{value}"

  @spec section(String.t(), [String.t()]) :: String.t()
  defp section(heading, []), do: heading <> "\n  (none)\n"
  defp section(heading, lines), do: heading <> "\n" <> Enum.map_join(lines, "\n", &("  " <> &1))

  @spec render_plans([map()]) :: [String.t()]
  defp render_plans([]), do: []

  defp render_plans(plans) do
    Enum.flat_map(plans, fn plan ->
      ["#{plan.id}#{version_suffix(plan.version)} (price #{plan.price})"] ++
        Enum.map(plan.features, fn {feature, kind} -> "  #{feature}: #{kind}" end) ++ [""]
    end)
  end

  # The default version is not printed, so a plans module that declares no
  # versions reads exactly as it did before core schema version 10.
  @spec version_suffix(String.t()) :: String.t()
  defp version_suffix(version) do
    if version == AuroraMeter.Plan.base_version(), do: "", else: " version #{inspect(version)}"
  end

  @spec render_references([map()]) :: [String.t()]
  defp render_references([]), do: []

  defp render_references(references) do
    Enum.map(references, fn reference ->
      "#{reference.source}: #{render_list(reference.features)}"
    end) ++ [""]
  end

  @spec render_undeclared([map()]) :: [String.t()]
  defp render_undeclared([]), do: []

  defp render_undeclared(undeclared) do
    Enum.map(undeclared, fn entry ->
      "#{inspect(entry.feature)} is referenced by #{entry.source} and declared by no plan"
    end) ++ [""]
  end

  @spec render_gaps([map()]) :: [String.t()]
  defp render_gaps([]), do: []

  defp render_gaps(gaps) do
    Enum.map(gaps, fn gap ->
      "#{inspect(gap.feature)}: declared on #{render_list(gap.declared_in)}; " <>
        "would be denied on #{render_list(gap.would_deny)}"
    end) ++ [""]
  end

  @spec render_list([atom()]) :: String.t()
  defp render_list([]), do: "(none)"
  defp render_list(items), do: Enum.map_join(items, ", ", &inspect/1)
end
