defmodule AuroraMeter.Counter do
  @moduledoc """
  The hot path: atomic ETS counter operations.

  Increments use `:ets.update_counter/3` (lock-free, concurrency-safe). A cold key
  is seeded once from the last flushed database value so the in-ETS value is
  always absolute; after that first touch the path is pure ETS. Every mutation
  marks the key dirty (for the flusher) and touched (for the broadcaster).

  Two key shapes share the table:

    * `{tenant_key, feature, period_start}` — the billing-period counter that
      entitlements and reporting read
    * `{tenant_key, feature, {:day, date}}` — a UTC day bucket, maintained
      alongside the period counter when `:history` is enabled, feeding
      `AuroraMeter.history/3`
  """

  alias AuroraMeter.Config
  alias AuroraMeter.Storage
  alias AuroraMeter.Store

  @typedoc "A period counter key: `{tenant_key, feature, period_start}`."
  @type period_key :: {String.t(), atom(), DateTime.t()}

  @typedoc "A history counter key: `{tenant_key, feature, {:day, date}}`."
  @type day_key :: {String.t(), atom(), {:day, Date.t()}}

  @typedoc "Any counter key."
  @type key :: period_key() | day_key()

  @doc "Increments a period counter by `qty` and returns the new value."
  @spec incr(String.t(), atom(), integer(), DateTime.t()) :: integer()
  def incr(tenant_key, feature, qty, period_start) do
    new = bump({tenant_key, feature, period_start}, qty)
    bump_history(tenant_key, feature, qty)
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
    new = bump(key, qty)

    if is_integer(limit) and new > limit do
      bump(key, -qty)
      {:error, :limit_exceeded}
    else
      bump_history(tenant_key, feature, qty)
      :ok
    end
  end

  @doc "Releases a previously reserved `qty` (rollback on a raised function)."
  @spec release(String.t(), atom(), integer(), DateTime.t()) :: :ok
  def release(tenant_key, feature, qty, period_start) do
    bump({tenant_key, feature, period_start}, -qty)
    bump_history(tenant_key, feature, -qty)
    :ok
  end

  @doc "Returns the current value for a period counter (rehydrating from the database if cold)."
  @spec value(String.t(), atom(), DateTime.t()) :: integer()
  def value(tenant_key, feature, period_start), do: read({tenant_key, feature, period_start})

  @doc "Returns the current value of a UTC day bucket (rehydrating from the database if cold)."
  @spec day_value(String.t(), atom(), Date.t()) :: integer()
  def day_value(tenant_key, feature, date), do: read({tenant_key, feature, {:day, date}})

  @doc "Returns a map of `feature => value` for a tenant's warm period counters in a period."
  @spec all_for(String.t(), DateTime.t()) :: %{atom() => integer()}
  def all_for(tenant_key, period_start) do
    table()
    |> :ets.match({{tenant_key, :"$1", period_start}, :"$2"})
    |> Map.new(fn [feature, value] -> {feature, value} end)
  end

  @doc "Returns `date => value` for a feature's warm day buckets (no database access)."
  @spec warm_day_values(String.t(), atom()) :: %{Date.t() => integer()}
  def warm_day_values(tenant_key, feature) do
    table()
    |> :ets.match({{tenant_key, feature, {:day, :"$1"}}, :"$2"})
    |> Map.new(fn [date, value] -> {date, value} end)
  end

  @doc "Marks a counter key dirty (pending flush) and touched (pending broadcast)."
  @spec mark_dirty(key()) :: :ok
  def mark_dirty(key) do
    :ets.insert(Store.dirty_table(), {key})
    :ets.insert(Store.touched_table(), {key})
    :ok
  end

  @doc "Snapshots the current set of dirty keys."
  @spec dirty_keys() :: [key()]
  def dirty_keys, do: keys(Store.dirty_table())

  @doc "Removes a single key from the dirty set."
  @spec clear_dirty(key()) :: :ok
  def clear_dirty(key) do
    :ets.delete(Store.dirty_table(), key)
    :ok
  end

  @doc "Snapshots the current set of touched keys."
  @spec touched_keys() :: [key()]
  def touched_keys, do: keys(Store.touched_table())

  @doc "Removes a single key from the touched set."
  @spec clear_touched(key()) :: :ok
  def clear_touched(key) do
    :ets.delete(Store.touched_table(), key)
    :ok
  end

  @doc "Whether a key is a history (day bucket) key."
  @spec history_key?(key()) :: boolean()
  def history_key?({_tenant_key, _feature, {:day, %Date{}}}), do: true
  def history_key?(_key), do: false

  @spec bump(key(), integer()) :: integer()
  defp bump(key, qty) do
    ensure_seeded(key)
    new = :ets.update_counter(table(), key, {2, qty})
    mark_dirty(key)
    new
  end

  @spec bump_history(String.t(), atom(), integer()) :: :ok
  defp bump_history(tenant_key, feature, qty) do
    if Config.history?(), do: bump({tenant_key, feature, {:day, Date.utc_today()}}, qty)
    :ok
  end

  @spec read(key()) :: integer()
  defp read(key) do
    ensure_seeded(key)
    [{^key, val}] = :ets.lookup(table(), key)
    val
  end

  @spec keys(atom()) :: [key()]
  defp keys(table), do: table |> :ets.tab2list() |> Enum.map(&elem(&1, 0))

  @spec ensure_seeded(key()) :: :ok
  defp ensure_seeded(key) do
    if :ets.member(table(), key) do
      :ok
    else
      :ets.insert_new(table(), {key, stored_value(key) || 0})
      :ok
    end
  end

  @spec stored_value(key()) :: integer() | nil
  defp stored_value({tenant_key, feature, {:day, date}}),
    do: Storage.load_history(tenant_key, feature, date)

  defp stored_value({tenant_key, feature, period_start}),
    do: Storage.load_counter(tenant_key, feature, period_start)

  @spec table() :: atom()
  defp table, do: Store.counters_table()
end
