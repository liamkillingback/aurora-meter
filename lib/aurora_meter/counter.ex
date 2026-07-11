defmodule AuroraMeter.Counter do
  @moduledoc """
  The hot path: atomic ETS counter operations.

  Increments use `:ets.update_counter/3` (lock-free, concurrency-safe). A cold key
  is seeded once from the last flushed database value (`ensure_seeded/4`) so the
  in-ETS value is always absolute; after that first touch the path is pure ETS.
  Every mutation marks the key dirty for the flusher.
  """

  alias AuroraMeter.Storage
  alias AuroraMeter.Store

  @typedoc "A counter key: `{tenant_key, feature, period_start}`."
  @type key :: {String.t(), atom(), DateTime.t()}

  @doc "Increments a counter by `qty` and returns the new value."
  @spec incr(String.t(), atom(), integer(), DateTime.t()) :: integer()
  def incr(tenant_key, feature, qty, period_start) do
    key = {tenant_key, feature, period_start}
    ensure_seeded(key, tenant_key, feature, period_start)
    new = :ets.update_counter(table(), key, {2, qty})
    mark_dirty(key)
    new
  end

  @doc """
  Atomically reserves `qty` against an optional hard `limit`.

  Increments first; if the new value exceeds `limit` it rolls the increment back
  and returns `{:error, :limit_exceeded}`. A `nil` limit always succeeds.
  """
  @spec reserve(String.t(), atom(), integer(), DateTime.t(), non_neg_integer() | nil) ::
          :ok | {:error, :limit_exceeded}
  def reserve(tenant_key, feature, qty, period_start, limit) do
    key = {tenant_key, feature, period_start}
    ensure_seeded(key, tenant_key, feature, period_start)
    new = :ets.update_counter(table(), key, {2, qty})
    mark_dirty(key)

    if is_integer(limit) and new > limit do
      :ets.update_counter(table(), key, {2, -qty})
      mark_dirty(key)
      {:error, :limit_exceeded}
    else
      :ok
    end
  end

  @doc "Releases a previously reserved `qty` (rollback on a raised function)."
  @spec release(String.t(), atom(), integer(), DateTime.t()) :: :ok
  def release(tenant_key, feature, qty, period_start) do
    key = {tenant_key, feature, period_start}
    ensure_seeded(key, tenant_key, feature, period_start)
    :ets.update_counter(table(), key, {2, -qty})
    mark_dirty(key)
    :ok
  end

  @doc "Returns the current value for a counter (rehydrating from the database if cold)."
  @spec value(String.t(), atom(), DateTime.t()) :: integer()
  def value(tenant_key, feature, period_start) do
    key = {tenant_key, feature, period_start}
    ensure_seeded(key, tenant_key, feature, period_start)
    [{^key, val}] = :ets.lookup(table(), key)
    val
  end

  @doc "Returns a map of `feature => value` for a tenant's warm counters in a period."
  @spec all_for(String.t(), DateTime.t()) :: %{atom() => integer()}
  def all_for(tenant_key, period_start) do
    table()
    |> :ets.match({{tenant_key, :"$1", period_start}, :"$2"})
    |> Map.new(fn [feature, value] -> {feature, value} end)
  end

  @doc "Marks a counter key dirty so the flusher persists it."
  @spec mark_dirty(key()) :: :ok
  def mark_dirty(key) do
    :ets.insert(Store.dirty_table(), {key})
    :ok
  end

  @doc "Snapshots the current set of dirty keys."
  @spec dirty_keys() :: [key()]
  def dirty_keys do
    Store.dirty_table()
    |> :ets.tab2list()
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Removes a single key from the dirty set."
  @spec clear_dirty(key()) :: :ok
  def clear_dirty(key) do
    :ets.delete(Store.dirty_table(), key)
    :ok
  end

  @spec ensure_seeded(key(), String.t(), atom(), DateTime.t()) :: :ok
  defp ensure_seeded(key, tenant_key, feature, period_start) do
    if :ets.member(table(), key) do
      :ok
    else
      base = Storage.load_counter(tenant_key, feature, period_start) || 0
      :ets.insert_new(table(), {key, base})
      :ok
    end
  end

  @spec table() :: atom()
  defp table, do: Store.counters_table()
end
