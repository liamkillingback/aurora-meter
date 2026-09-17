if Code.ensure_loaded?(AuroraMeter.Pro) do
  defmodule AuroraMeterExampleAi.Pro.Billing do
    @moduledoc """
    What the `/billing` page reads and does, all of it through Aurora Meter
    Pro's public API.

    ## There is nothing simulated in here

    Every function on this module either reads a row Stripe's webhook wrote, or
    asks Stripe to create something real in **test mode**. There is no
    "pretend success" path, no local flag that stands in for a payment, and no
    branch that grants credit because a redirect came back. Credit is granted
    by `AuroraMeter.Pro.Credits.handle_event/1` when the webhook arrives, and
    by nothing else.

    That is not fastidiousness. A sample that granted credit on the success
    redirect would teach a reader to grant credit on a URL a customer can type,
    which is the single most expensive mistake in this area.

    ## What the page can and cannot tell you

    | Question | Answered by | Where the fact lives |
    |---|---|---|
    | which plan is this organisation on | `AuroraMeter.Subscriptions.get/1` | the local subscription row, synced from Stripe by the webhook |
    | how much credit is there | `AuroraMeter.Credits.summary/1` | the ledger |
    | is there a saved card | `AuroraMeter.Pro.Credits.account/1` | the credit account row |
    | did my top-up land | nothing on this page | the ledger, after the webhook. Until then the page says "waiting", and it means it |
    """

    alias AuroraMeter.Credits
    alias AuroraMeter.Pro.Credits, as: ProCredits
    alias AuroraMeter.Subscriptions

    @typedoc "Everything `/billing` renders, read in one pass."
    @type view :: %{
            plan_id: atom() | nil,
            plan_version: String.t() | nil,
            status: String.t() | nil,
            current_period_end: DateTime.t() | nil,
            summary: Credits.summary(),
            account: map() | nil,
            presets_cents: [pos_integer()],
            auto_top_up: map()
          }

    @doc """
    Reads everything the page shows, in one pass.

    Snapshot semantics, and the page says so: these are several queries, not
    one serialised read, so a webhook landing between two of them moves one
    figure and not another. On an operations page that is worth stating rather
    than hiding, and `/ops` states it too.
    """
    @spec load(term()) :: view()
    def load(tenant) do
      subscription = Subscriptions.get(tenant)
      account = ProCredits.account(tenant)

      %{
        plan_id: subscription && subscription.plan_id,
        plan_version: subscription && Map.get(subscription, :plan_version),
        status: subscription && to_string(subscription.status),
        current_period_end: subscription && Map.get(subscription, :current_period_end),
        summary: Credits.summary(tenant),
        account: account,
        presets_cents: ProCredits.presets_cents(),
        auto_top_up: auto_top_up(account)
      }
    end

    @doc """
    Creates a **real** test-mode Checkout Session for a top-up and returns its
    URL.

    The caller redirects the browser to it. Nothing is granted here: the grant
    happens when `checkout.session.completed` or `payment_intent.succeeded`
    reaches the webhook.
    """
    @spec top_up_url(term(), pos_integer(), keyword()) ::
            {:ok, String.t()} | {:error, :invalid_amount | term()}
    def top_up_url(tenant, amount_cents, opts \\ []) do
      ProCredits.checkout(tenant, amount_cents, opts)
    end

    @doc """
    A Billing Portal URL, where a customer manages the saved card.

    `{:error, :no_customer}` when this organisation has never paid, which is
    the ordinary state of a new organisation and is rendered as an explanation
    rather than as an error.
    """
    @spec portal_url(term(), keyword()) :: {:ok, String.t()} | {:error, :no_customer | term()}
    def portal_url(tenant, opts \\ []), do: ProCredits.portal_url(tenant, opts)

    @doc """
    A subscription Checkout Session for a plan, through the configured billing
    provider.

    Goes through `AuroraMeter.Billing` rather than through
    `AuroraMeter.Pro.Stripe` directly, because the provider is a core seam and
    a host should be able to change it in configuration. The Pro profile
    configures `provider: AuroraMeter.Pro.Stripe`; the core profile has no
    provider configured at all and no page that would call this.
    """
    @spec subscribe_url(term(), atom(), keyword()) :: {:ok, String.t()} | {:error, term()}
    def subscribe_url(tenant, plan_id, opts \\ []) do
      # `AuroraMeter.Billing.checkout/3`, which is the core facade's name for
      # it. The provider behaviour's callback is `create_checkout_session/2`
      # and the facade folds `plan_id` into its options; calling the callback
      # name on the facade compiles with a warning and raises at runtime, which
      # is a five-minute mistake worth one line of comment.
      case AuroraMeter.Billing.checkout(tenant, plan_id, opts) do
        {:ok, %{url: url}} -> {:ok, url}
        {:ok, url} when is_binary(url) -> {:ok, url}
        other -> other
      end
    end

    @doc """
    Turns auto-recharge on or off.

    `{:error, :no_payment_method}` when there is no saved card, which is Pro
    refusing to arm a charge it has no way to make. The page renders that
    refusal as the sentence it is.
    """
    @spec set_auto_top_up(term(), map()) :: {:ok, map()} | {:error, term()}
    def set_auto_top_up(tenant, attrs), do: ProCredits.update_auto_top_up(tenant, attrs)

    @doc """
    The auto-recharge settings, flattened for the page, with `nil` rendered as
    "off" rather than as a blank.
    """
    @spec auto_top_up(map() | nil) :: map()
    def auto_top_up(nil) do
      %{
        enabled: false,
        threshold_micro: nil,
        amount_cents: nil,
        card: nil,
        failures: 0,
        # Present and `nil` rather than absent: the page reads every key, and a
        # map that is missing one for a tenant who has never paid is a
        # `KeyError` on the first render of `/billing` for a new organisation.
        # Which is exactly what happened.
        disabled_reason: nil
      }
    end

    def auto_top_up(account) do
      %{
        enabled: Map.get(account, :auto_top_up_enabled, false),
        threshold_micro: Map.get(account, :threshold_micro),
        amount_cents: Map.get(account, :amount_cents),
        card: card_label(account),
        failures: Map.get(account, :failure_count, 0) || 0,
        disabled_reason: Map.get(account, :disabled_reason)
      }
    end

    # Only ever the brand and the last four, which is what Stripe itself shows
    # a customer. The sample never renders a PAN, an expiry or a token, and
    # there is nowhere in this application that could: the credit account row
    # holds a payment method id and a label, and that is all Pro stores.
    defp card_label(account) do
      case {Map.get(account, :payment_method_brand), Map.get(account, :payment_method_last4)} do
        {brand, last4} when is_binary(brand) and is_binary(last4) -> "#{brand} ...#{last4}"
        _none -> nil
      end
    end
  end
end
