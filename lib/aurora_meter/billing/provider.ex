defmodule AuroraMeter.Billing.Provider do
  @moduledoc """
  Behaviour for a billing provider. The core ships `AuroraMeter.Billing.Noop`;
  the Pro package provides a Stripe implementation. Only ever call a provider
  through the `AuroraMeter.Billing` facade.

  ## Four required callbacks and two optional ones

  The first four are what every provider has to answer. The last two exist for
  scheduled plan changes (build unit 07b) and are optional because a plan change
  that needs no provider is free core functionality (decision D03): a host
  moving a tenant between locally declared plans has a complete feature with no
  provider at all, and `AuroraMeter.Billing.Noop` implements neither.

  Resolution is by `function_exported?/3`, so a provider gains the behaviour by
  defining the function and nothing else. `AuroraMeter.Config.validate!/0`
  checks only the required set, subtracting whatever this behaviour declares
  optional, so a provider written before these existed still boots.
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

  @doc """
  Describes what moving `tenant` to `{plan_id, version}` means to the provider.

  **Optional.** Called by `AuroraMeter.Subscriptions.preview_transition/3`, and
  by nothing that writes. The map is opaque to core and is rendered as the
  `provider` section of a preview: a price id, an interval, a proration mode.
  Core never interprets it, and never computes a proration of its own.

  A provider that has no mapping for the target returns `{:error, reason}`; the
  preview then reports `%{status: :error, detail: %{reason: reason}}` and still
  returns the entitlement diff, which is core's and is right regardless.
  """
  @callback describe_plan_change(tenant :: term(), to :: {atom(), String.t()}, opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Asks the provider to make the plan change, before it is applied locally.

  **Optional**, and implemented by Aurora Meter Pro in build unit 07c. It is the
  "provider first, local second" half of task 07.07: the local transition stays
  `pending` and visible until the provider's subscription shows the new price,
  at which point `AuroraMeter.Subscriptions.confirm_transition/3` records the
  provider's reference and applies it.
  """
  @callback update_subscription_plan(
              tenant :: term(),
              to :: {atom(), String.t()},
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @optional_callbacks describe_plan_change: 3, update_subscription_plan: 3
end
