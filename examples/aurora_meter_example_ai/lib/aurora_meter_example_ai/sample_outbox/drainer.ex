defmodule AuroraMeterExampleAi.SampleOutbox.Drainer do
  @moduledoc """
  Delivers staged export intents to an `AuroraMeter.Exporter`, on its own
  connection, after the transaction that staged them has committed.

  It ticks, claims a bounded batch with `FOR UPDATE SKIP LOCKED`, hands the
  batch to the exporter, and writes back one state per item. The exporter here
  is `AuroraMeter.Exporter.Journal`, the deterministic reference
  implementation: it records what it was given and answers what it was told to,
  so every outcome below is reachable from a test without a mocked HTTP layer.

  ## The five outcomes and what each leaves behind

  | Outcome | State | Retried? |
  |---|---|---|
  | `:accepted` | `delivered` | no |
  | `{:accepted, ref}` | `delivered`, with the provider reference stored | no |
  | `{:retry, seconds}` | back to `pending`, `attempts + 1`, `next_attempt_at` set | yes, automatically |
  | `:uncertain` | `uncertain` | **never automatically** |
  | `{:rejected, reason}` | `rejected`, with the reason stored | no |

  `:uncertain` is the one that matters. It means the provider may or may not
  have taken the item, and nobody knows. Retrying could double bill and
  abandoning could under bill, so the only correct automatic behaviour is to
  stop and make it visible, which is what `/ops` does. A human decides.

  The adapter's return value is never read directly: `AuroraMeter.Exporter`
  owns the one interpretation of it, through `normalize/2`, so that a missing
  entry reads as `:uncertain` here exactly as it does in Aurora Meter Pro.

  ## What this is not

  Aurora Meter Pro's outbox adds lease tokens and fencing. `SKIP LOCKED` alone
  makes two drainers claim disjoint rows, which is enough for this sample, but
  it does not survive a worker that claims a batch and then hangs: nothing can
  tell that worker's claim from a live one except time. The reclaim below is a
  timeout, and a timeout is a guess.
  """
  use GenServer

  import Ecto.Query

  require Logger

  alias AuroraMeter.Exporter
  alias AuroraMeterExampleAi.Repo
  alias AuroraMeterExampleAi.SampleOutbox.Item

  @default_interval 1_000
  @default_batch 20
  # How long a claimed row waits before another tick may take it back.
  @reclaim_after_seconds 30

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Runs one tick synchronously and returns what it did.

  Tests call this instead of waiting for the timer, which is the difference
  between a suite that is deterministic and one that is usually deterministic.
  """
  @spec drain_now(keyword()) :: %{
          claimed: non_neg_integer(),
          outcomes: %{String.t() => integer()}
        }
  def drain_now(opts \\ []), do: tick(Keyword.get(opts, :batch, @default_batch))

  @impl GenServer
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    batch = Keyword.get(opts, :batch, @default_batch)
    if interval > 0, do: Process.send_after(self(), :tick, interval)
    {:ok, %{interval: interval, batch: batch}}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    try do
      tick(state.batch)
    rescue
      # A drainer that dies on a database blip takes nothing with it, but it
      # does stop draining, and a supervisor restart loses the tick. Logging
      # and carrying on is right here; Pro's version records the failure.
      error -> Logger.warning("outbox tick failed: #{Exception.message(error)}")
    end

    if state.interval > 0, do: Process.send_after(self(), :tick, state.interval)
    {:noreply, state}
  end

  @spec tick(pos_integer()) :: %{claimed: non_neg_integer(), outcomes: map()}
  defp tick(batch_size) do
    case claim(batch_size) do
      [] ->
        %{claimed: 0, outcomes: %{}}

      items ->
        exporter = Application.get_env(:aurora_meter_example_ai, :exporter, Exporter.Journal)
        deliverables = Enum.map(items, &to_exporter_item/1)
        raw = exporter.deliver(deliverables, %{attempt_started_at: DateTime.utc_now()})

        outcomes =
          case Exporter.normalize(deliverables, raw) do
            {:ok, by_id} -> by_id
            # An adapter that answered for an item it was never given is a bug
            # in the adapter. Every item this batch owns is left uncertain,
            # which is the honest reading of "the answer made no sense".
            {:error, {:unknown_ids, _ids}} -> Map.new(deliverables, &{&1.id, :uncertain})
          end

        counts =
          items
          |> Enum.map(fn item -> apply_outcome(item, Map.get(outcomes, item.id, :uncertain)) end)
          |> Enum.frequencies()

        %{claimed: length(items), outcomes: counts}
    end
  end

  # One statement: select the eligible ids with SKIP LOCKED and mark them
  # claimed in the same update, so no two ticks can take the same row and a row
  # being delivered is never also pending.
  @spec claim(pos_integer()) :: [Item.t()]
  defp claim(batch_size) do
    now = DateTime.utc_now()
    reclaim_before = DateTime.add(now, -@reclaim_after_seconds, :second)

    eligible =
      from(i in Item,
        where:
          (i.state == "pending" and (is_nil(i.next_attempt_at) or i.next_attempt_at <= ^now)) or
            (i.state == "claimed" and i.updated_at <= ^reclaim_before),
        order_by: [asc: i.inserted_at],
        limit: ^batch_size,
        lock: "FOR UPDATE SKIP LOCKED",
        select: i.id
      )

    {_count, claimed} =
      Repo.update_all(
        from(i in Item, where: i.id in subquery(eligible), select: i),
        set: [state: "claimed", updated_at: now]
      )

    claimed || []
  end

  @spec to_exporter_item(Item.t()) :: Exporter.Item.t()
  defp to_exporter_item(item) do
    Exporter.item!(%{
      id: item.id,
      subject_kind: :event,
      subject_ref: item.event_id,
      tenant_key: item.tenant_key,
      payload: item.payload,
      attempts: item.attempts,
      first_attempt_at: nil
    })
  end

  @spec apply_outcome(Item.t(), Exporter.outcome()) :: String.t()
  defp apply_outcome(item, outcome) do
    {state, fields, increments} = transition(outcome)

    updates = [
      set: [{:state, state}, {:updated_at, DateTime.utc_now()} | fields],
      inc: increments
    ]

    Repo.update_all(from(i in Item, where: i.id == ^item.id), updates)

    state
  end

  # `{state, fields to set, counters to increment}`. Only a retry increments
  # `attempts`: an accepted, rejected or uncertain item is not going to be sent
  # again, so counting the attempt that ended it would make the figure mean two
  # different things depending on where it stopped.
  @spec transition(Exporter.outcome()) :: {String.t(), keyword(), keyword()}
  defp transition(:accepted),
    do: {"delivered", [last_outcome: "accepted", next_attempt_at: nil], []}

  defp transition({:accepted, ref}),
    do:
      {"delivered",
       [last_outcome: "accepted", provider_ref: to_string(ref), next_attempt_at: nil], []}

  defp transition({:retry, delay}) do
    seconds = delay || 5

    {"pending",
     [
       last_outcome: "retry:#{seconds}",
       next_attempt_at: DateTime.add(DateTime.utc_now(), seconds, :second)
     ], [attempts: 1]}
  end

  defp transition(:uncertain),
    do: {"uncertain", [last_outcome: "uncertain", next_attempt_at: nil], []}

  defp transition({:rejected, reason}),
    do: {"rejected", [last_outcome: "rejected:#{reason}", next_attempt_at: nil], []}
end
