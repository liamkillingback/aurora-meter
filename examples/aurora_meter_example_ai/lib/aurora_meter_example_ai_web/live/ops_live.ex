defmodule AuroraMeterExampleAiWeb.OpsLive do
  @moduledoc """
  What an operator needs and a customer does not: the conservation identity, the
  credit lots in spend order, the outbox, the two reporting sources side by
  side, and any orphaned event.

  It shows **this** organisation's internals and only this organisation's,
  because every figure comes from `AuroraMeterExampleAi.Ops`, which takes the
  session scope. There is no organisation switcher and no organisation
  parameter. An operational page that reads a tenant out of the URL is the one
  security defect this whole arrangement is built to make impossible.
  """
  use AuroraMeterExampleAiWeb, :live_view

  alias AuroraMeterExampleAi.Ops

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Operations") |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("drain", _params, socket) do
    result = AuroraMeterExampleAi.SampleOutbox.Drainer.drain_now()

    {:noreply,
     socket
     |> put_flash(:info, "Drained #{result.claimed} item(s): #{inspect(result.outcomes)}")
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_info({:aurora_meter, _tag, _payload}, socket), do: {:noreply, load(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  defp load(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:conservation, Ops.conservation(scope))
    |> assign(:lots, Ops.lots(scope))
    |> assign(:allocations, Ops.allocations(scope))
    |> assign(:outbox_states, Ops.outbox_states(scope))
    |> assign(:outbox_items, Ops.outbox_items(scope, limit: 25))
    |> assign(:deliveries, Ops.deliveries(scope))
    |> assign(:sources, Ops.sources(scope))
    |> assign(:orphans, Ops.orphans(scope))
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.sample_nav current_scope={@current_scope} />

      <h1 class="text-2xl font-semibold">Operations</h1>
      <p class="text-sm opacity-70">
        {@current_scope.org.name}, tenant key <code>{@conservation.tenant_key}</code>.
      </p>

      <div class="flex gap-2 my-2">
        <button phx-click="refresh" class="btn btn-sm">Refresh</button>
        <button phx-click="drain" class="btn btn-sm">Drain the outbox now</button>
      </div>

      <h2 class="text-lg font-semibold mt-6">Conservation</h2>
      <p class="text-xs opacity-60">
        Every ledger entry ever written for this wallet, added up, against what the
        summary reports. It is a snapshot taken with several queries, not a
        serialised total: a generation completing between two reads moves one
        figure and not the other.
      </p>
      <div id="conservation" data-holds={to_string(@conservation.holds)}>
        <.figure label="entries" value={@conservation.entries} />
        <.figure label="sum of amount" value={money(@conservation.ledger_balance)} />
        <.figure label="summary balance" value={money(@conservation.summary_balance)} />
        <.figure label="sum of held_delta" value={money(@conservation.ledger_held)} />
        <.figure label="summary held" value={money(@conservation.summary_held)} />
        <.figure label="summary available" value={money(@conservation.summary_available)} />
        <.figure
          label="balance minus held equals available"
          value={yes_no(@conservation.available_holds)}
        />
        <.figure label="identity holds" value={yes_no(@conservation.holds)} />
      </div>

      <h2 class="text-lg font-semibold mt-6">Credit lots, in spend order</h2>
      <p class="text-xs opacity-60">
        Promotional before paid, earliest expiry first, then the oldest grant. The
        next micro-dollar spent comes out of the top row.
      </p>
      <table class="table table-sm w-full" id="lots">
        <thead>
          <tr>
            <th>reference</th>
            <th>category</th>
            <th>state</th>
            <th>amount</th>
            <th>available</th>
            <th>reserved</th>
            <th>consumed</th>
            <th>expires</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={lot <- @lots} id={"lot-#{lot.id}"}>
            <td class="font-mono text-xs">{lot.reference}</td>
            <td>{lot.category}</td>
            <td>{lot.state}</td>
            <td>{money(lot.amount)}</td>
            <td>{money(lot.available)}</td>
            <td>{money(lot.reserved)}</td>
            <td>{money(lot.consumed)}</td>
            <td>{lot.expires_at || "never"}</td>
          </tr>
        </tbody>
      </table>

      <h2 class="text-lg font-semibold mt-6">Where each movement came from</h2>
      <table class="table table-sm w-full" id="allocations">
        <thead>
          <tr>
            <th>kind</th>
            <th>from</th>
            <th>to</th>
            <th>amount</th>
            <th>lot</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={allocation <- Enum.take(@allocations, 25)}>
            <td>{allocation.kind}</td>
            <td>{allocation.from_bucket}</td>
            <td>{allocation.to_bucket}</td>
            <td>{money(allocation.amount)}</td>
            <td class="font-mono text-xs">{lot_reference(@lots, allocation.lot_id)}</td>
          </tr>
        </tbody>
      </table>

      <h2 class="text-lg font-semibold mt-6">One input source, one commercial effect</h2>
      <p class="text-xs opacity-60">
        <code>tokens</code>
        is an events-source feature: its billable fact is the durable event, and its
        counter is a projection of those events. <code>images</code>
        is buffered: it lives in memory, it is flushed on an interval, and it never
        becomes an event. The last row is the one to read.
      </p>
      <div id="sources">
        <.figure label="tokens counter (projected)" value={@sources.tokens_counter} />
        <.figure
          label="tokens staged, net of corrections"
          value={@sources.tokens_outbox_quantity}
          hint="this is the figure to compare with the counter"
        />
        <.figure
          label="tokens staged, gross"
          value={@sources.tokens_outbox_gross}
          hint="a correction's quantity is a positive magnitude, so the gross sum counts it as an increase"
        />
        <.figure label="of which corrections" value={@sources.tokens_outbox_corrections} />
        <.figure label="token outbox rows" value={@sources.tokens_outbox_rows} />
        <.figure label="images counter (buffered)" value={@sources.images_counter} />
        <.figure
          label="image outbox rows"
          value={@sources.images_outbox_rows}
          hint="a buffered feature never reaches the outbox"
        />
      </div>

      <h2 class="text-lg font-semibold mt-6">Outbox</h2>
      <div id="outbox-states">
        <.figure :for={{state, count} <- Enum.sort(@outbox_states)} label={state} value={count} />
      </div>
      <p :if={Map.get(@outbox_states, "uncertain", 0) > 0} class="alert alert-warning" role="status">
        An uncertain item may or may not have reached the provider. Retrying could bill
        twice and abandoning could bill nothing, so nothing is retried automatically
        and a person decides.
      </p>

      <table class="table table-sm w-full" id="outbox-items">
        <thead>
          <tr>
            <th>event</th>
            <th>feature</th>
            <th>quantity</th>
            <th>state</th>
            <th>attempts</th>
            <th>last outcome</th>
            <th>age</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={item <- @outbox_items} id={"outbox-#{item.id}"}>
            <td class="font-mono text-xs">{item.event_id}</td>
            <td>{item.feature}</td>
            <td>{item.quantity}</td>
            <td>{item.state}</td>
            <td>{item.attempts}</td>
            <td>{item.last_outcome || "-"}</td>
            <td>{age(item.inserted_at)}</td>
          </tr>
        </tbody>
      </table>

      <h2 class="text-lg font-semibold mt-6">What the reference exporter was handed</h2>
      <p class="text-xs opacity-60">
        The journal is an Agent. It is a dry run and a teaching aid, and it is gone
        when this node stops. It is not a record of what was billed.
      </p>
      <div id="deliveries">
        <.figure
          :for={entry <- Enum.take(@deliveries, 20)}
          label={entry.item.subject_ref}
          value={inspect(entry.outcome)}
          hint={"attempt #{entry.attempt}"}
        />
        <p :if={@deliveries == []} class="opacity-70 text-sm">Nothing delivered yet.</p>
      </div>

      <h2 class="text-lg font-semibold mt-6">Orphans</h2>
      <p class="text-xs opacity-60">
        An event that committed with its export intent, and whose local row never
        got written. Run <code>mix sample.repair</code> to rebuild what can be
        rebuilt.
      </p>
      <div id="orphans" data-count={length(@orphans)}>
        <.figure :for={item <- @orphans} label={item.event_id} value={item.quantity} hint="tokens" />
        <p :if={@orphans == []} class="opacity-70 text-sm">None.</p>
      </div>
    </Layouts.app>
    """
  end

  defp lot_reference(lots, lot_id) do
    case Enum.find(lots, &(&1.id == lot_id)) do
      nil -> lot_id
      lot -> lot.reference
    end
  end

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "NO"

  defp age(nil), do: "-"

  defp age(at) do
    seconds = DateTime.diff(DateTime.utc_now(), at, :second)
    "#{seconds}s"
  end
end
