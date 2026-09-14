defmodule AuroraMeter.Test.FaultStorage do
  @moduledoc """
  An `AuroraMeter.Storage` shim that can fail at a callback boundary (build unit
  01b).

  Every callback delegates to `AuroraMeter.Storage.Ecto` and wraps the
  delegation in two checks:

      Faults.check(:before_commit, %{callback: :flush_batch, ...})
      result = Backend.flush_batch(id, counters, history)
      Faults.check(:after_commit_before_ack, %{callback: :flush_batch, ...})

  `:after_commit_before_ack` is the "commit succeeded, reply lost" boundary from
  `financial-correctness-review.md` section 1: the backend has committed and the
  caller never learns of it.

  Install it inside a region so it is always removed:

      AuroraMeter.Test.Config.with_config(
        [{:aurora_meter, :storage, AuroraMeter.Test.FaultStorage}],
        fn -> ... end
      )

  `uncovered_callbacks/1` is the parity guard: when `AuroraMeter.Storage` grows
  a callback this shim does not wrap, the harness self-test names it. The guard
  reads this module's own source rather than its exports, so a callback that is
  implemented but not instrumented is caught too.
  """

  @behaviour AuroraMeter.Storage

  alias AuroraMeter.Storage.Ecto, as: Backend
  alias AuroraMeter.Test.Faults

  @source __ENV__.file

  @impl AuroraMeter.Storage
  def flush_batch(id, counters, history) do
    Faults.check(:before_commit, %{
      callback: :flush_batch,
      batch_id: id,
      counters: length(counters),
      history: length(history)
    })

    result = Backend.flush_batch(id, counters, history)

    Faults.check(:after_commit_before_ack, %{callback: :flush_batch, batch_id: id, result: result})

    result
  end

  @impl AuroraMeter.Storage
  def upsert_counters(rows) do
    Faults.check(:before_commit, %{callback: :upsert_counters, rows: length(rows)})
    result = Backend.upsert_counters(rows)
    Faults.check(:after_commit_before_ack, %{callback: :upsert_counters, result: result})
    result
  end

  @impl AuroraMeter.Storage
  def add_counters(rows) do
    Faults.check(:before_commit, %{callback: :add_counters, rows: length(rows)})
    result = Backend.add_counters(rows)
    Faults.check(:after_commit_before_ack, %{callback: :add_counters, result: result})
    result
  end

  @impl AuroraMeter.Storage
  def load_counter(tenant_key, feature, period_start) do
    Faults.check(:before_commit, %{callback: :load_counter, tenant_key: tenant_key})
    result = Backend.load_counter(tenant_key, feature, period_start)
    Faults.check(:after_commit_before_ack, %{callback: :load_counter, result: result})
    result
  end

  @impl AuroraMeter.Storage
  def upsert_history(rows) do
    Faults.check(:before_commit, %{callback: :upsert_history, rows: length(rows)})
    result = Backend.upsert_history(rows)
    Faults.check(:after_commit_before_ack, %{callback: :upsert_history, result: result})
    result
  end

  @impl AuroraMeter.Storage
  def add_history(rows) do
    Faults.check(:before_commit, %{callback: :add_history, rows: length(rows)})
    result = Backend.add_history(rows)
    Faults.check(:after_commit_before_ack, %{callback: :add_history, result: result})
    result
  end

  @impl AuroraMeter.Storage
  def load_history(tenant_key, feature, date) do
    Faults.check(:before_commit, %{callback: :load_history, tenant_key: tenant_key})
    result = Backend.load_history(tenant_key, feature, date)
    Faults.check(:after_commit_before_ack, %{callback: :load_history, result: result})
    result
  end

  @impl AuroraMeter.Storage
  def load_history_range(tenant_key, feature, from, to) do
    Faults.check(:before_commit, %{callback: :load_history_range, tenant_key: tenant_key})
    result = Backend.load_history_range(tenant_key, feature, from, to)
    Faults.check(:after_commit_before_ack, %{callback: :load_history_range, result: result})
    result
  end

  @impl AuroraMeter.Storage
  def get_subscription(tenant_key) do
    Faults.check(:before_commit, %{callback: :get_subscription, tenant_key: tenant_key})
    result = Backend.get_subscription(tenant_key)
    Faults.check(:after_commit_before_ack, %{callback: :get_subscription, result: result})
    result
  end

  @impl AuroraMeter.Storage
  def put_subscription(attrs) do
    Faults.check(:before_commit, %{callback: :put_subscription, attrs: attrs})
    result = Backend.put_subscription(attrs)
    Faults.check(:after_commit_before_ack, %{callback: :put_subscription, result: result})
    result
  end

  @impl AuroraMeter.Storage
  def insert_events(rows) do
    Faults.check(:before_commit, %{callback: :insert_events, rows: length(rows)})
    result = Backend.insert_events(rows)
    Faults.check(:after_commit_before_ack, %{callback: :insert_events, result: result})
    result
  end

  @impl AuroraMeter.Storage
  def stream_counters(period_start) do
    Faults.check(:before_commit, %{callback: :stream_counters, period_start: period_start})
    result = Backend.stream_counters(period_start)
    Faults.check(:after_commit_before_ack, %{callback: :stream_counters, result: result})
    result
  end

  @doc """
  The callbacks of `behaviour` this shim implements *and* instruments with
  `AuroraMeter.Test.Faults.check/2`, read from this module's source.
  """
  @spec instrumented_callbacks() :: [{atom(), non_neg_integer()}]
  def instrumented_callbacks do
    @source
    |> File.read!()
    |> Code.string_to_quoted!()
    |> collect_instrumented()
    |> Enum.sort()
  end

  @doc """
  The callbacks `behaviour` declares that this shim does not instrument.

  `[]` is the only acceptable value. A non-empty list means production grew a
  storage callback and the shim can no longer fail at that boundary, which
  would make every later proof that rests on it vacuous.
  """
  @spec uncovered_callbacks(module()) :: [{atom(), non_neg_integer()}]
  def uncovered_callbacks(behaviour \\ AuroraMeter.Storage) do
    instrumented = MapSet.new(instrumented_callbacks())

    behaviour.behaviour_info(:callbacks)
    |> Enum.reject(&MapSet.member?(instrumented, &1))
    |> Enum.sort()
  end

  defp collect_instrumented(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:def, _, [{name, _, args}, body]} = node, acc when is_atom(name) and is_list(args) ->
          if checks_faults?(body), do: {node, [{name, length(args)} | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp checks_faults?(body) do
    {_ast, found} =
      Macro.prewalk(body, false, fn
        {{:., _, [{:__aliases__, _, [:Faults]}, :check]}, _, _} = node, _acc -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end
end
