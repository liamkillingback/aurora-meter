defmodule AuroraMeter.Billing.Provider do
  @moduledoc """
  Behaviour for a billing provider. The core ships `AuroraMeter.Billing.Noop`;
  the Pro package provides a Stripe implementation. Only ever call a provider
  through the `AuroraMeter.Billing` facade.
  """

  @doc "Creates a checkout session and returns a redirect URL."
  @callback create_checkout_session(tenant :: term(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Returns a billing-portal URL for the tenant."
  @callback billing_portal_url(tenant :: term(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Syncs a provider subscription payload into local storage."
  @callback sync_subscription(payload :: map()) :: {:ok, term()} | {:error, term()}

  @doc "Reports metered usage entries to the provider."
  @callback report_usage(entries :: list()) :: :ok | {:error, term()}
end
