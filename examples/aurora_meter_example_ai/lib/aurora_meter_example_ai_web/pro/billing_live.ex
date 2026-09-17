if Code.ensure_loaded?(AuroraMeter.Pro) do
  defmodule AuroraMeterExampleAiWeb.Pro.BillingLive do
    @moduledoc """
    The Pro profile's `/billing` page: the subscription, the credit account,
    auto-recharge, and the two buttons that send a browser to **real** Stripe
    test-mode checkout.

    ## What this page is careful about

    Nothing on it says a payment succeeded. The success return sets a notice
    that says Stripe reported the session complete and that the credit appears
    when the webhook lands, and the figure beside it is read from the ledger
    every time. If the webhook has not arrived, the figure has not moved and
    the page does not pretend it has.

    That distinction is the whole reason the page exists in a sample. A
    redirect back from a payment page is a message from the customer's browser.
    The money is the webhook.

    ## It is absent in the core profile

    This module is not compiled at all without Aurora Meter Pro, its route is
    not in the router's table, and `/generate` has no link to it. A reader with
    no licence has no billing surface, working or broken.
    """
    use AuroraMeterExampleAiWeb, :live_view

    alias AuroraMeterExampleAi.Pro.Billing
    alias AuroraMeterExampleAi.Tenancy

    @impl Phoenix.LiveView
    def mount(_params, _session, socket) do
      {:ok,
       socket
       |> assign(:page_title, "Billing")
       |> assign(:notice, nil)
       |> assign(:pending_since, nil)
       |> load()}
    end

    @impl Phoenix.LiveView
    def handle_params(params, _uri, socket) do
      {:noreply, socket |> apply_return(params) |> load()}
    end

    # The two returns Stripe can send a browser back on. Neither of them
    # changes a figure: they set a sentence.
    defp apply_return(socket, %{"checkout" => "success"}) do
      socket
      |> assign(
        :notice,
        {:info,
         "Stripe reported the checkout session complete. Credit is granted when the webhook " <>
           "arrives, not when this page loads: the balance below is the ledger's own figure. " <>
           "If it has not moved, the event has not landed yet, and /ops shows what has."}
      )
      |> assign(:pending_since, DateTime.utc_now())
    end

    defp apply_return(socket, %{"checkout" => "cancelled"}) do
      assign(
        socket,
        :notice,
        {:info, "Checkout was cancelled. Nothing was charged and nothing was granted."}
      )
    end

    defp apply_return(socket, _params), do: socket

    @impl Phoenix.LiveView
    def handle_event("top_up", %{"cents" => cents}, socket) do
      org = socket.assigns.current_scope.org
      amount = String.to_integer(cents)

      case Billing.top_up_url(org, amount,
             success_url: url(~p"/billing?checkout=success"),
             cancel_url: url(~p"/billing?checkout=cancelled")
           ) do
        {:ok, stripe_url} ->
          # `redirect(external:)` and not `push_navigate`: this leaves the
          # application entirely, for a page Stripe hosts and this sample has
          # never seen.
          {:noreply, redirect(socket, external: stripe_url)}

        {:error, reason} ->
          {:noreply, assign(socket, :notice, {:error, describe(reason)})}
      end
    end

    def handle_event("subscribe", %{"plan" => plan}, socket) do
      org = socket.assigns.current_scope.org

      case Billing.subscribe_url(org, String.to_existing_atom(plan),
             success_url: url(~p"/billing?checkout=success"),
             cancel_url: url(~p"/billing?checkout=cancelled")
           ) do
        {:ok, stripe_url} -> {:noreply, redirect(socket, external: stripe_url)}
        {:error, reason} -> {:noreply, assign(socket, :notice, {:error, describe(reason)})}
      end
    end

    def handle_event("portal", _params, socket) do
      org = socket.assigns.current_scope.org

      case Billing.portal_url(org, return_url: url(~p"/billing")) do
        {:ok, stripe_url} -> {:noreply, redirect(socket, external: stripe_url)}
        {:error, reason} -> {:noreply, assign(socket, :notice, {:error, describe(reason)})}
      end
    end

    def handle_event("auto_top_up", %{"auto" => attrs}, socket) do
      org = socket.assigns.current_scope.org

      params = %{
        auto_top_up_enabled: attrs["enabled"] == "true",
        threshold_micro: to_int(attrs["threshold_micro"]),
        amount_cents: to_int(attrs["amount_cents"])
      }

      case Billing.set_auto_top_up(org, params) do
        {:ok, _account} ->
          {:noreply, socket |> assign(:notice, {:info, "Auto-recharge saved."}) |> load()}

        {:error, reason} ->
          {:noreply, socket |> assign(:notice, {:error, describe(reason)}) |> load()}
      end
    end

    @impl Phoenix.LiveView
    def handle_info({:aurora_meter, tag, _payload} = message, socket)
        when tag in [:credits, :low_balance] do
      {:noreply, message |> AuroraMeter.LiveView.handle_credits(socket) |> load()}
    end

    def handle_info(_other, socket), do: {:noreply, socket}

    @impl Phoenix.LiveView
    def render(assigns) do
      ~H"""
      <Layouts.app flash={@flash} current_scope={@current_scope}>
        <.sample_nav current_scope={@current_scope} />

        <h1 class="text-2xl font-semibold">Billing</h1>
        <p class="text-sm opacity-70">
          Aurora Meter Pro, against a <strong>Stripe test-mode</strong>
          account. Every button here creates a real object in that account and the
          <code>4242 4242 4242 4242</code>
          card is the only one to use.
        </p>

        <div :if={@notice} id="billing-notice" class={notice_class(@notice)} role="status">
          {elem(@notice, 1)}
        </div>

        <section class="mt-6">
          <h2 class="text-lg font-semibold">Subscription</h2>
          <.figure label="Plan" value={@view.plan_id || "none"} />
          <.figure label="Plan version" value={@view.plan_version || "-"} />
          <.figure label="Status" value={@view.status || "no subscription"} />
          <.figure label="Current period ends" value={stamp(@view.current_period_end)} />
          <p class="text-xs opacity-60 mt-1">
            These four are read from the local subscription row, which the webhook syncs from
            Stripe. Nothing here is written by this page.
          </p>
          <button
            :if={is_nil(@view.status)}
            id="subscribe-studio"
            phx-click="subscribe"
            phx-value-plan="studio"
            class="btn btn-primary mt-2"
          >
            Subscribe to studio at Stripe
          </button>
        </section>

        <section class="mt-6">
          <h2 class="text-lg font-semibold">Credit</h2>
          <.figure label="Balance" value={money(@view.summary.balance)} />
          <.figure label="Held" value={money(@view.summary.held)} />
          <.figure label="Available" value={money(@view.summary.available)} hint="balance - held" />
          <.figure
            label="Spendable"
            value={money(@view.summary.spendable)}
            hint="what a hold would be allowed to take"
          />
          <.figure label="Debt" value={money(@view.summary.debt)} />
          <p :if={@view.summary.debt > 0} class="text-xs mt-1">
            While this wallet owes anything, both spendable figures read zero whatever the
            balance says, and every hold is refused with <code>:debt_outstanding</code>.
          </p>
        </section>

        <section class="mt-6">
          <h2 class="text-lg font-semibold">Top up</h2>
          <div class="flex gap-2 mt-2">
            <button
              :for={cents <- @view.presets_cents}
              id={"top-up-#{cents}"}
              phx-click="top_up"
              phx-value-cents={cents}
              class="btn"
            >
              Top up {cents_label(cents)}
            </button>
          </div>
          <p class="text-xs opacity-60 mt-1">
            This creates a Stripe Checkout Session and sends you to Stripe. The credit appears
            on the ledger when the webhook reports the payment, and not before.
          </p>
        </section>

        <section class="mt-6">
          <h2 class="text-lg font-semibold">Auto-recharge</h2>
          <.figure label="Enabled" value={@view.auto_top_up.enabled} />
          <.figure label="Threshold" value={money(@view.auto_top_up.threshold_micro || 0)} />
          <.figure label="Amount" value={cents_label(@view.auto_top_up.amount_cents || 0)} />
          <.figure label="Saved card" value={@view.auto_top_up.card || "none"} />
          <.figure label="Consecutive failures" value={@view.auto_top_up.failures} />
          <.figure
            :if={@view.auto_top_up.disabled_reason}
            label="Disabled because"
            value={@view.auto_top_up.disabled_reason}
          />

          <form phx-submit="auto_top_up" class="mt-2 flex flex-wrap gap-2 items-end" id="auto-form">
            <label class="text-sm">
              Threshold (micro-USD)
              <input
                type="number"
                name="auto[threshold_micro]"
                value={@view.auto_top_up.threshold_micro}
                class="input input-bordered input-sm"
              />
            </label>
            <label class="text-sm">
              Amount (cents)
              <input
                type="number"
                name="auto[amount_cents]"
                value={@view.auto_top_up.amount_cents}
                class="input input-bordered input-sm"
              />
            </label>
            <label class="text-sm">
              <input
                type="checkbox"
                name="auto[enabled]"
                value="true"
                checked={@view.auto_top_up.enabled}
              /> Enabled
            </label>
            <button class="btn btn-sm" type="submit">Save</button>
          </form>

          <p class="text-xs opacity-60 mt-1">
            Arming this needs a saved card, and Aurora Meter Pro refuses with
            <code>:no_payment_method</code>
            when there is none rather than arming a charge it cannot make. Top up once first;
            the checkout saves the card for off-session use.
          </p>

          <button id="portal" phx-click="portal" class="btn btn-sm mt-2">
            Manage the card at Stripe
          </button>
        </section>

        <p class="text-xs opacity-60 mt-8">
          Every figure on this page is a separate query, so one landing between two reads moves
          one figure and not another. That is stated rather than hidden, exactly as on /ops.
        </p>
      </Layouts.app>
      """
    end

    defp load(socket) do
      assign(socket, :view, Billing.load(Tenancy.org!(socket.assigns.current_scope)))
    end

    defp notice_class({:error, _}), do: "alert alert-error"
    defp notice_class(_), do: "alert alert-info"

    defp stamp(nil), do: "-"
    defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

    defp cents_label(cents) when is_integer(cents),
      do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

    defp cents_label(_other), do: "-"

    defp to_int(nil), do: nil
    defp to_int(""), do: nil
    defp to_int(value) when is_binary(value), do: String.to_integer(value)

    defp describe(:no_customer),
      do:
        "This organisation has never paid, so there is no Stripe customer to manage yet. " <>
          "Top up once and the card is saved."

    defp describe(:no_payment_method),
      do:
        "Auto-recharge needs a saved card. Aurora Meter Pro refuses to arm a charge it has " <>
          "no way to make, which is the right refusal."

    defp describe(:invalid_amount),
      do: "That amount is outside the configured minimum and maximum."

    defp describe(:not_configured),
      do:
        "No Stripe price is mapped for that plan. Set AURORA_STRIPE_PRICE_STUDIO; see " <>
          ".env.example."

    defp describe(other), do: "Stripe refused: #{inspect(other)}"
  end
end
