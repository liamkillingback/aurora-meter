defmodule AuroraMeter.Billing.Noop do
  @moduledoc """
  Default billing provider: every operation returns `{:error, :not_configured}`.

  Lets the free core work with no billing provider installed. Configure
  `AuroraMeter.Pro.Stripe` (or another `AuroraMeter.Billing.Provider`) to enable
  real billing.
  """

  @behaviour AuroraMeter.Billing.Provider

  @impl AuroraMeter.Billing.Provider
  def create_checkout_session(_tenant, _opts), do: {:error, :not_configured}

  @impl AuroraMeter.Billing.Provider
  def billing_portal_url(_tenant, _opts), do: {:error, :not_configured}

  @impl AuroraMeter.Billing.Provider
  def sync_subscription(_payload), do: {:error, :not_configured}

  @impl AuroraMeter.Billing.Provider
  def report_usage(_entries), do: {:error, :not_configured}
end
