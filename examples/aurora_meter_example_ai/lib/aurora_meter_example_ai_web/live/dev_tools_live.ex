defmodule AuroraMeterExampleAiWeb.DevToolsLive do
  @moduledoc """
  Developer tools: a clearly labelled synthetic grant, a plan switch, and the
  organisation's API key.

  **There is no payment anywhere in this profile of the sample.** No card form,
  no checkout, no pricing page that leads to one, and no screen that says a
  payment succeeded. Credit arrives here or from `mix sample.seed`, and both say
  so on the page. A sample that showed a fake successful payment would be
  teaching the one thing a billing example must never teach.

  The page refuses unless `config :aurora_meter_example_ai, :dev_tools` is true,
  and the route is behind the host's owner check as well. Two locks, because
  this is the page that mints money.
  """
  use AuroraMeterExampleAiWeb, :live_view

  alias AuroraMeter.Credits

  @grant_amount 2_000_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if Application.get_env(:aurora_meter_example_ai, :dev_tools, false) do
      {:ok, socket |> assign(:page_title, "Developer tools") |> load()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Developer tools are switched off in this environment.")
       |> redirect(to: ~p"/generate")}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("grant", _params, socket) do
    org = socket.assigns.current_scope.org
    reference = "synthetic:devtools:#{org.slug}:#{System.unique_integer([:positive])}"

    case Credits.grant(org, @grant_amount, reference: reference, category: :paid) do
      {:ok, _txn} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Granted #{money(@grant_amount)} of synthetic credit. No payment was taken."
         )
         |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Refused: #{inspect(reason)}")}
    end
  end

  # The plan id is matched against a literal list rather than turned into an
  # atom. `String.to_atom/1` on anything a browser sent is an unbounded atom
  # table, and `to_existing_atom/1` only narrows it to every atom the VM has
  # ever loaded, which is not the same as "a plan this application has".
  def handle_event("plan", %{"plan" => plan}, socket) when plan in ["free", "studio"] do
    org = socket.assigns.current_scope.org
    plan_id = if plan == "free", do: :free, else: :studio
    AuroraMeter.subscribe(org, plan_id)

    {:noreply,
     socket
     |> put_flash(:info, "Assigned the #{plan} plan locally. No payment was involved.")
     |> load()}
  end

  def handle_event("allowance", _params, socket) do
    {:ok, report} = Credits.Recurrences.run(tenant: socket.assigns.current_scope.org)

    {:noreply, socket |> put_flash(:info, "Recurring allowances: #{inspect(report)}") |> load()}
  end

  @impl Phoenix.LiveView
  def handle_info({:aurora_meter, _tag, _payload}, socket), do: {:noreply, load(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  defp load(socket) do
    org = socket.assigns.current_scope.org
    plan = AuroraMeter.plan(org)

    socket
    |> assign(:summary, Credits.summary(org))
    |> assign(:plan_id, (plan && plan.id) || "none")
    # `@grant_amount` inside a HEEx template would be `assigns.grant_amount`,
    # not the module attribute, so the attribute is assigned rather than
    # referenced. It is the commonest surprise in a first HEEx template.
    |> assign(:grant_amount, @grant_amount)
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.sample_nav current_scope={@current_scope} />

      <h1 class="text-2xl font-semibold">Developer tools</h1>

      <div class="alert alert-info" role="note" id="no-payment-notice">
        Everything on this page is synthetic. This sample takes no money, has no
        card form and has no provider. The grant below is an entry in the local
        credit ledger and nothing else.
      </div>

      <h2 class="text-lg font-semibold mt-4">Credit</h2>
      <.figure label="available" value={money(@summary.available)} />
      <.figure label="spendable" value={money(@summary.spendable)} hint="zero while a wallet owes" />
      <.figure label="promotional" value={money(@summary.promotional)} />
      <.figure label="held" value={money(@summary.held)} />
      <.figure label="debt" value={money(@summary.debt)} />

      <button phx-click="grant" class="btn btn-primary mt-2" id="synthetic-grant">
        Add {money(@grant_amount)} of synthetic credit
      </button>

      <h2 class="text-lg font-semibold mt-6">Plan</h2>
      <p class="text-sm">
        Currently <strong>{@plan_id}</strong>, assigned locally. No payment involved.
      </p>
      <div class="flex gap-2">
        <button phx-click="plan" phx-value-plan="free" class="btn btn-sm">Assign free</button>
        <button phx-click="plan" phx-value-plan="studio" class="btn btn-sm">Assign studio</button>
        <button phx-click="allowance" class="btn btn-sm">
          Run the recurring allowance now
        </button>
      </div>

      <h2 class="text-lg font-semibold mt-6">API key</h2>
      <p class="text-sm">
        For <code>POST /api/generate</code>. This sample stores the key in plain text
        so it can print it for you; a real application stores a hash of it and shows
        the plaintext once.
      </p>
      <pre class="text-xs" id="api-key">{@current_scope.org.api_key}</pre>
    </Layouts.app>
    """
  end
end
