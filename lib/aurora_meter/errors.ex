defmodule AuroraMeter.UndeclaredFeatureError do
  @moduledoc """
  Raised by the entitlement functions when `:undeclared_feature_policy` is
  `:raise` and the tenant's plan does not declare the feature.

  "Undeclared" means *not on this tenant's effective plan*. A feature some other
  plan declares is still undeclared here: that is the case the policy exists
  for, because a `:free` tenant reaching a `:pro` only feature used to be
  answered permissively. `reason` separates the two, `:not_in_plan` from
  `:unknown_feature`, for logs and telemetry; the outcome is the same.

  `AuroraMeter.track/4` never raises this: metering is not entitlement.
  """

  @typedoc "Whether the feature is declared on some other plan, or on none at all."
  @type reason :: :not_in_plan | :unknown_feature

  @type t :: %__MODULE__{
          feature: atom(),
          tenant_key: String.t() | nil,
          plan_id: atom() | nil,
          entry_point: atom(),
          reason: reason()
        }

  defexception [:feature, :tenant_key, :plan_id, :entry_point, :reason, :message]

  @impl true
  @spec exception(keyword()) :: t()
  def exception(opts) do
    feature = Keyword.fetch!(opts, :feature)
    tenant_key = Keyword.get(opts, :tenant_key)
    plan_id = Keyword.get(opts, :plan_id)
    entry_point = Keyword.fetch!(opts, :entry_point)
    reason = Keyword.fetch!(opts, :reason)

    %__MODULE__{
      feature: feature,
      tenant_key: tenant_key,
      plan_id: plan_id,
      entry_point: entry_point,
      reason: reason,
      message: message(feature, tenant_key, plan_id, entry_point, reason)
    }
  end

  @spec message(atom(), String.t() | nil, atom() | nil, atom(), reason()) :: String.t()
  defp message(feature, tenant_key, plan_id, entry_point, reason) do
    "AuroraMeter.#{entry_point}: feature #{inspect(feature)} is not declared on plan " <>
      "#{inspect(plan_id)} for tenant #{inspect(tenant_key)}. " <>
      elaborate(reason) <>
      " The configured :undeclared_feature_policy is :raise. Declare the feature on the " <>
      "plan, or set `config :aurora_meter, undeclared_feature_policy: :allow` to restore " <>
      "the 0.4.x behaviour."
  end

  @spec elaborate(reason()) :: String.t()
  defp elaborate(:not_in_plan), do: "Another plan declares it; this one does not."
  defp elaborate(:unknown_feature), do: "No plan declares it."
end

defmodule AuroraMeter.Credits.CurrencyMismatchError do
  @moduledoc """
  Raised at boot when `:credits_currency` does not match the currency already
  stamped on this installation's credit balance rows.

  The currency is stamped once, when a balance row is created, and nothing
  re-reads it afterwards. Changing the setting on a wallet set that already has
  rows therefore used to leave two currencies side by side with no check, and
  every figure computed across them was meaningless. V1 is USD only (D06), so
  this stops the boot instead.
  """

  @type t :: %__MODULE__{configured: String.t(), stored: [{String.t(), non_neg_integer()}]}

  defexception [:configured, :stored, :message]

  @impl true
  @spec exception(keyword()) :: t()
  def exception(opts) do
    configured = Keyword.fetch!(opts, :configured)
    stored = Keyword.fetch!(opts, :stored)

    %__MODULE__{configured: configured, stored: stored, message: message(configured, stored)}
  end

  @spec message(String.t(), [{String.t(), non_neg_integer()}]) :: String.t()
  defp message(configured, stored) do
    counts =
      Enum.map_join(stored, ", ", fn {currency, count} ->
        "#{inspect(currency)} on #{count} #{rows(count)}"
      end)

    "config :aurora_meter, credits_currency: #{inspect(configured)} does not match the " <>
      "currency already stored on aurora_meter_credit_balances (#{counts}). Aurora Meter " <>
      "stamps the currency once, when a balance row is created, so a wallet set with two " <>
      "currencies has no meaningful total. Either restore the previous credits_currency, " <>
      "or migrate the rows deliberately before changing it. V1 supports USD only."
  end

  @spec rows(non_neg_integer()) :: String.t()
  defp rows(1), do: "row"
  defp rows(_count), do: "rows"
end
