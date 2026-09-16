defmodule AuroraMeter.Test.FakeProvider do
  @moduledoc """
  Billing providers for the transition preview (build unit 07b).

  Three of them, because the preview has three provider outcomes and only a
  module that really does each one can tell them apart:
  `AuroraMeter.Billing.Noop` implements neither optional callback, `Describing`
  implements both, `Erroring` returns `{:error, reason}` and `Raising` raises.

  These ship in no archive: `elixirc_paths(:test)` compiles `test/support`.
  """

  defmodule Describing do
    @moduledoc "Implements both optional callbacks and answers with a mapping."

    @behaviour AuroraMeter.Billing.Provider

    @impl AuroraMeter.Billing.Provider
    def create_checkout_session(_tenant, _opts), do: {:error, :not_configured}

    @impl AuroraMeter.Billing.Provider
    def billing_portal_url(_tenant, _opts), do: {:error, :not_configured}

    @impl AuroraMeter.Billing.Provider
    def sync_subscription(_payload), do: {:error, :not_configured}

    @impl AuroraMeter.Billing.Provider
    def report_usage(_entries), do: {:error, :not_configured}

    @impl AuroraMeter.Billing.Provider
    def describe_plan_change(_tenant, {plan_id, version}, _opts) do
      {:ok,
       %{
         price_id: "price_#{plan_id}_v#{version}_month",
         interval: "month",
         proration_behavior: "none"
       }}
    end

    @impl AuroraMeter.Billing.Provider
    def update_subscription_plan(_tenant, {plan_id, version}, _opts) do
      {:ok, %{provider_ref: "sub_#{plan_id}_v#{version}"}}
    end
  end

  defmodule Erroring do
    @moduledoc "Implements `describe_plan_change/3` and has no mapping for the target."

    @behaviour AuroraMeter.Billing.Provider

    @impl AuroraMeter.Billing.Provider
    def create_checkout_session(_tenant, _opts), do: {:error, :not_configured}

    @impl AuroraMeter.Billing.Provider
    def billing_portal_url(_tenant, _opts), do: {:error, :not_configured}

    @impl AuroraMeter.Billing.Provider
    def sync_subscription(_payload), do: {:error, :not_configured}

    @impl AuroraMeter.Billing.Provider
    def report_usage(_entries), do: {:error, :not_configured}

    @impl AuroraMeter.Billing.Provider
    def describe_plan_change(_tenant, _to, _opts), do: {:error, :no_price_for_version}
  end

  defmodule Raising do
    @moduledoc "Implements `describe_plan_change/3` and raises inside it."

    @behaviour AuroraMeter.Billing.Provider

    @impl AuroraMeter.Billing.Provider
    def create_checkout_session(_tenant, _opts), do: {:error, :not_configured}

    @impl AuroraMeter.Billing.Provider
    def billing_portal_url(_tenant, _opts), do: {:error, :not_configured}

    @impl AuroraMeter.Billing.Provider
    def sync_subscription(_payload), do: {:error, :not_configured}

    @impl AuroraMeter.Billing.Provider
    def report_usage(_entries), do: {:error, :not_configured}

    @impl AuroraMeter.Billing.Provider
    def describe_plan_change(_tenant, _to, _opts) do
      raise RuntimeError, "the provider's HTTP client is not started"
    end
  end
end
