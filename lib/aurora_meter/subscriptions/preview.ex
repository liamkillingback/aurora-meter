defmodule AuroraMeter.Subscriptions.Preview do
  @moduledoc false

  # The dry run behind `AuroraMeter.Subscriptions.preview_transition/3` (build
  # unit 07b, task 07.09).
  #
  # A pure read: no lock, no transaction, no write, safe from a LiveView render.
  # The diff is computed from two `AuroraMeter.Plan` structs, so it is exactly
  # what the tenant's entitlements will be, resolved through the same
  # `AuroraMeter.Plans.get/2` that `AuroraMeter.Entitlements.plan/1` uses.
  #
  # `price` is the plan's declared list price in cents. It is **not** an invoice
  # amount: core computes no proration of any kind (decision D05, task 07.05)
  # and Stripe is authoritative for what a customer is charged. The provider
  # section is the only place a price id or a proration mode can appear, and it
  # is whatever the provider's optional `describe_plan_change/3` returned.

  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Entitlements
  alias AuroraMeter.Period
  alias AuroraMeter.Plan
  alias AuroraMeter.Plans
  alias AuroraMeter.Subscriptions.Transitions
  alias AuroraMeter.Tenant

  @doc false
  @spec build(term(), atom() | String.t(), keyword()) :: {:ok, map()} | {:error, {atom(), term()}}
  def build(tenant, to_plan, opts) do
    key = Tenant.to_key(tenant)

    with {:ok, plan_id} <- plan_id(to_plan),
         {:ok, effective_at} <- effective_at(tenant, opts[:effective_at]),
         {:ok, to} <- resolve(plan_id, opts[:version], effective_at) do
      {:ok, assemble(tenant, key, Entitlements.plan(key), to, effective_at)}
    end
  end

  defp assemble(tenant, key, from, to, effective_at) do
    %{
      from: describe(from),
      to: describe(to),
      changes: changes(from, to),
      effective_at: effective_at,
      period: Period.current!(tenant, Clock.now()),
      provider: provider(key, to)
    }
  end

  defp plan_id(id) when is_atom(id) and not is_nil(id), do: {:ok, id}

  defp plan_id(id) when is_binary(id) do
    case Transitions.plan_atom(id) do
      nil -> {:error, {:invalid, [to_plan: "is not a known plan"]}}
      atom -> {:ok, atom}
    end
  end

  defp plan_id(_id), do: {:error, {:invalid, [to_plan: "is not a known plan"]}}

  defp effective_at(tenant, nil), do: {:ok, Period.current!(tenant, Clock.now()).end}

  defp effective_at(_tenant, %DateTime{time_zone: "Etc/UTC"} = at), do: {:ok, at}

  defp effective_at(_tenant, _other),
    do: {:error, {:invalid, [effective_at: "must be a UTC DateTime"]}}

  defp resolve(plan_id, version, effective_at) do
    case {Plans.versions(plan_id), version} do
      {[], _any} -> {:error, {:invalid, [to_plan: "is not a known plan"]}}
      {versions, nil} -> effective_version(versions, effective_at)
      {_versions, named} -> named_version(plan_id, named)
    end
  end

  defp effective_version(versions, effective_at) do
    versions
    |> Enum.filter(fn plan ->
      is_nil(plan.effective_at) or DateTime.compare(plan.effective_at, effective_at) != :gt
    end)
    |> List.last()
    |> case do
      nil -> {:error, {:invalid, [to_plan: "has no version effective at that time"]}}
      plan -> {:ok, plan}
    end
  end

  defp named_version(plan_id, version) when is_binary(version) do
    case Plans.get(plan_id, version) do
      nil -> {:error, {:invalid, [to_plan_version: "is not a known version of this plan"]}}
      plan -> {:ok, plan}
    end
  end

  defp named_version(_plan_id, _version),
    do: {:error, {:invalid, [to_plan_version: "must be a string"]}}

  defp describe(%Plan{} = plan) do
    %{
      plan_id: plan.id,
      version: plan.version,
      price: plan.price,
      features: plan.features,
      recurring_credits: plan.recurring_credits
    }
  end

  # -- the diff ---------------------------------------------------------------

  defp changes(%Plan{} = from, %Plan{} = to) do
    feature_changes(from.features, to.features) ++
      credit_changes(from.recurring_credits, to.recurring_credits)
  end

  defp feature_changes(from, to) do
    from
    |> Map.keys()
    |> Kernel.++(Map.keys(to))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&feature_change(&1, Map.get(from, &1), Map.get(to, &1)))
  end

  defp feature_change(_name, same, same), do: []

  defp feature_change(name, nil, to),
    do: [%{kind: :feature, name: name, from: nil, to: to, direction: :added}]

  defp feature_change(name, from, nil),
    do: [%{kind: :feature, name: name, from: from, to: nil, direction: :removed}]

  defp feature_change(name, from, to),
    do: [%{kind: :feature, name: name, from: from, to: to, direction: direction(from, to)}]

  defp direction({:limit, a, mode}, {:limit, b, mode}), do: compare(a, b)

  defp direction({:metered, included_a, price_a}, {:metered, included_b, price_b}) do
    case compare(included_a, included_b) do
      :changed -> compare(price_b, price_a)
      other -> other
    end
  end

  defp direction({:feature, a}, {:feature, b}) when is_boolean(a) and is_boolean(b) do
    compare(boolean_rank(a), boolean_rank(b))
  end

  defp direction({:feature, a}, {:feature, b}) when is_integer(a) and is_integer(b) do
    compare(a, b)
  end

  defp direction(_from, _to), do: :changed

  defp compare(a, b) when a < b, do: :increase
  defp compare(a, b) when a > b, do: :decrease
  defp compare(_a, _b), do: :changed

  defp boolean_rank(true), do: 1
  defp boolean_rank(false), do: 0

  defp credit_changes(from, to) do
    from_by_name = Map.new(from, &{&1.name, &1})
    to_by_name = Map.new(to, &{&1.name, &1})

    from_by_name
    |> Map.keys()
    |> Kernel.++(Map.keys(to_by_name))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&credit_change(&1, Map.get(from_by_name, &1), Map.get(to_by_name, &1)))
  end

  defp credit_change(_name, same, same), do: []

  defp credit_change(name, nil, to),
    do: [%{kind: :recurring_credits, name: name, from: nil, to: to, direction: :added}]

  defp credit_change(name, from, nil),
    do: [%{kind: :recurring_credits, name: name, from: from, to: nil, direction: :removed}]

  defp credit_change(name, from, to) do
    [
      %{
        kind: :recurring_credits,
        name: name,
        from: from,
        to: to,
        direction: compare(from.amount, to.amount)
      }
    ]
  end

  # -- the provider section ---------------------------------------------------

  # `describe_plan_change/3` is optional, so a free installation gets
  # `:not_configured` rather than a crash and rather than a fabricated mapping.
  # A provider that raises or errors gets `:error` and the entitlement diff is
  # still returned, because that half is core's and is right whatever the
  # provider says.
  defp provider(key, %Plan{} = to) do
    module = Config.provider()

    if Code.ensure_loaded?(module) and function_exported?(module, :describe_plan_change, 3) do
      describe_change(module, key, to)
    else
      %{status: :not_configured, detail: %{}}
    end
  end

  defp describe_change(module, key, %Plan{} = to) do
    case module.describe_plan_change(key, {to.id, to.version}, []) do
      {:ok, detail} when is_map(detail) -> %{status: :ok, detail: detail}
      {:error, reason} -> %{status: :error, detail: %{reason: reason}}
      other -> %{status: :error, detail: %{reason: {:unexpected_return, other}}}
    end
  rescue
    exception -> %{status: :error, detail: %{reason: exception}}
  catch
    :exit, reason -> %{status: :error, detail: %{reason: {:exit, reason}}}
  end
end
