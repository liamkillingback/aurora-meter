defmodule AuroraMeterExampleAiWeb.HistoryLive do
  @moduledoc """
  This organisation's generations, with the identity of each one on all three
  sides: the local row, the durable event and the credit hold.

  `/history/:id` takes an id from the URL, and that is fine, because the id is
  looked up with `Generations.get!/2`, which takes the scope and filters on it.
  A generation belonging to another organisation raises `Ecto.NoResultsError`
  exactly as one that does not exist does, which is the right answer: from this
  caller's side those are the same fact, and telling them apart would leak
  whether an id exists.

  What the URL never carries is the **organisation**. That comes from the
  session, once, in `AuroraMeterExampleAiWeb.OrgHook`.
  """
  use AuroraMeterExampleAiWeb, :live_view

  alias AuroraMeterExampleAi.Generations

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "History")}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(:generations, Generations.list(scope))
     |> assign(:counts, Generations.counts(scope))
     |> assign(:selected, selected(scope, params))}
  end

  defp selected(scope, %{"id" => id}), do: Generations.get!(scope, id)
  defp selected(_scope, _params), do: nil

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.sample_nav current_scope={@current_scope} />

      <h1 class="text-2xl font-semibold">History</h1>
      <p class="text-sm opacity-70">
        {@current_scope.org.name}: {Map.get(@counts, "settled", 0)} settled, {Map.get(
          @counts,
          "rejected",
          0
        )} rejected, {Map.get(@counts, "released", 0)} released.
      </p>

      <div :if={@selected} id="selected" class="card bg-base-200 p-4 my-4">
        <h2 class="font-semibold">{@selected.id}</h2>
        <.figure label="status" value={@selected.status} />
        <.figure label="event id" value={@selected.event_id || "none"} />
        <.figure label="hold reference" value={@selected.hold_reference} />
        <.figure label="estimated" value={money(@selected.estimate_micros)} />
        <.figure label="settled" value={money(@selected.cost_micros)} />
        <.figure label="prompt" value={@selected.prompt} />
      </div>

      <table class="table table-sm w-full" id="generations">
        <thead>
          <tr>
            <th>when</th>
            <th>kind</th>
            <th>model</th>
            <th>status</th>
            <th>tokens</th>
            <th>estimated</th>
            <th>settled</th>
            <th>event</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={generation <- @generations} id={"generation-#{generation.id}"}>
            <td>
              <.link patch={"/history/#{generation.id}"}>
                {Calendar.strftime(generation.inserted_at, "%Y-%m-%d %H:%M:%S")}
              </.link>
            </td>
            <td>{generation.kind}</td>
            <td>{generation.model}</td>
            <td>{generation.status}</td>
            <td>{tokens(generation)}</td>
            <td>{money(generation.estimate_micros)}</td>
            <td>{money(generation.cost_micros)}</td>
            <td class="font-mono text-xs">{generation.event_id || "none"}</td>
          </tr>
        </tbody>
      </table>

      <p :if={@generations == []} class="opacity-70">
        Nothing yet. Run one from the generate page.
      </p>
    </Layouts.app>
    """
  end

  defp tokens(generation) do
    case Generations.Generation.total_tokens(generation) do
      nil -> "-"
      total -> total
    end
  end
end
