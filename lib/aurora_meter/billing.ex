defmodule AuroraMeter.Billing do
  @moduledoc """
  Facade over the configured `AuroraMeter.Billing.Provider`
  (`AuroraMeter.Config.provider/0`, default `AuroraMeter.Billing.Noop`).

  With only the free core installed these return `{:error, :not_configured}`;
  install and configure the Pro Stripe provider to enable checkout and billing.
  """

  @doc "Starts a checkout session for `plan_id` and returns a redirect URL."
  @spec checkout(term(), atom() | String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def checkout(tenant, plan_id, opts \\ []) do
    provider().create_checkout_session(tenant, Keyword.put(opts, :plan_id, plan_id))
  end

  @doc "Returns a billing-portal URL for the tenant."
  @spec portal_url(term(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def portal_url(tenant, opts \\ []) do
    provider().billing_portal_url(tenant, opts)
  end

  @spec provider() :: module()
  defp provider, do: AuroraMeter.Config.provider()
end
