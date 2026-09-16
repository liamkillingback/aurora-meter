defmodule AuroraMeter.Counter do
  @moduledoc """
  **Internal.** Not part of the supported API (see [API inventory](api.md)).
  It may change in any release, including a patch.

  The hot path: atomic ETS counter operations.

  Increments use a single `:ets.update_counter/3` call (lock-free,
  concurrency-safe). A cold key is seeded once from the last flushed database
  value so the in-ETS value is always absolute; after that first touch the path
  is pure ETS. Every mutation marks the key dirty (for the flusher) and touched
  (for the broadcaster).

  Each row is `{key, value, pending_flush, pending_gossip, remote, reserved}`:

    * `value` is this node's view of the **cluster-wide** total
    * `pending_flush` is what this node has added since its last database flush
    * `remote` is how much of `value` came from other nodes since the last
      rebase, so anything reasoning about what the *database* holds can tell
      that this node's view has moved for a reason the database has not
    * `pending_gossip` is what this node has added since its last PubSub tick
    * `reserved` occupies quota for unfinished `with_quota` work, but is not
      flushed or gossiped as completed usage

  The flusher writes `pending_flush` as a *delta* (`value = value + Δ`), so
  nodes add up instead of overwriting one another, then re-bases `value` on
  the total the database returns. The broadcaster ships `pending_gossip` to
  the other nodes so their views converge within one tick. See
  `AuroraMeter.Cluster` and the clustering guide.

  Two key shapes share the table:

    * `{tenant_key, feature, period_start}` — the billing-period counter that
      entitlements and reporting read
    * `{tenant_key, feature, {:day, date}}` — a UTC day bucket, maintained
      alongside the period counter when `:history` is enabled, feeding
      `AuroraMeter.history/3`

  ## Events-source features

  A feature configured `feature_sources: %{name => :events}` keeps a row here,
  because `AuroraMeter.usage/2` and the quota functions read it, but the row is
  maintained differently and two of its columns behave in ways that look wrong
  and are not.

  `pending_flush` stays at zero and the key is never marked dirty:
  `apply_projection/2` is the only writer of `value` for such a key other than a
  `with_quota` reservation, and it writes neither. That is what keeps a durable
  event out of `Store.snapshot_flush_batch/0`, out of `Storage.flush_batch/3`
  and therefore out of `aurora_meter_counters` (I08).

  `remote` grows without ever being cleared. `apply_remote/2` adds to it when a
  peer gossips a projected delta, and only `rebase/3` clears it: the flusher
  rebases the keys in a batch it wrote, and `AuroraMeter.Cluster` rebases the
  keys a peer announced in one, and an events-source key is in neither. A large
  `remote` on such a key is therefore the expected steady state, not a
  diagnostic. `remote_since_rebase/1` exists for the flusher's reasoning about
  buffered keys and has no caller that reaches these.

  There is no day bucket at all for an events-source feature: every caller of
  `bump_history/4` is either blocked by a guard (`incr/4` from
  `AuroraMeter.track/4`, the non-deferred branch of `reserve/6` from
  `AuroraMeter.reserve/2,3`) or not reached (`commit_work/5`, which
  `AuroraMeter.Entitlements.with_quota/4` does not call for these features). So
  `AuroraMeter.history/3` reports zeros; the durable series is
  `AuroraMeter.Events.stream/1`.
  """

  require Logger

  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Storage
  alias AuroraMeter.Store

  @typedoc "A period counter key: `{tenant_key, feature, period_start}`."
  @type period_key :: {String.t(), atom(), DateTime.t()}

  @typedoc "A history counter key: `{tenant_key, feature, {:day, date}}`."
  @type day_key :: {String.t(), atom(), {:day, Date.t()}}

  @typedoc "Any counter key."
  @type key :: period_key() | day_key()

  @typedoc "Which pending column to take: the database flush or the PubSub gossip."
  @type pending :: :flush | :gossip

  @value 2
  @pending_flush 3
  @pending_gossip 4
  @remote 5
  @reserved 6

  @doc "Increments a period counter by `qty` and returns the new value."
  @spec incr(String.t(), atom(), integer(), DateTime.t()) :: integer()
  def incr(tenant_key, feature, qty, period_start) do
    new = bump({tenant_key, feature, period_start}, qty)
    bump_history(tenant_key, feature, qty, Clock.today())
    new
  end

  @doc """
  Atomically reserves `qty` against an optional hard `limit`.

  Increments first; if the new value exceeds `limit` it rolls the increment back
  and returns `{:error, :limit_exceeded}`. A `nil` limit always succeeds.
  """
  @spec reserve(String.t(), atom(), integer(), DateTime.t(), non_neg_integer() | nil, boolean()) ::
          :ok | {:error, :limit_exceeded}
  def reserve(tenant_key, feature, qty, period_start, limit, deferred \\ false) do
    key = {tenant_key, feature, period_start}
    new = if deferred, do: reserve_pending(key, qty), else: bump(key, qty)

    if is_integer(limit) and new > limit do
      if deferred, do: release_work(tenant_key, feature, qty, period_start), else: bump(key, -qty)
      {:error, :limit_exceeded}
    else
      unless deferred, do: bump_history(tenant_key, feature, qty, Clock.today())
      :ok
    end
  end

  @doc false
  @spec commit_work(String.t(), atom(), integer(), DateTime.t(), Date.t()) :: :ok
  def commit_work(tenant_key, feature, qty, period_start, on) do
    key = {tenant_key, feature, period_start}

    # The Store can restart between `reserve_pending/2` and this call, and an
    # `:ets.update_counter/3` on a key that is no longer there raises
    # `ArgumentError` out of a callback that has already run (open finding C6).
    # Seeding first turns that into a correct, if cold, row.
    ensure_seeded(key)

    :ets.update_counter(table(), key, [
      {@reserved, -qty},
      {@pending_flush, qty},
      {@pending_gossip, qty}
    ])

    mark_dirty(key)
    bump_history(tenant_key, feature, qty, on)
  end

  @doc false
  @spec release_work(String.t(), atom(), integer(), DateTime.t()) :: :ok
  def release_work(tenant_key, feature, qty, period_start) do
    key = {tenant_key, feature, period_start}
    # As `commit_work/5`: a Store restart mid-callback must not turn a released
    # reservation into an `ArgumentError` (open finding C6).
    ensure_seeded(key)
    :ets.update_counter(table(), key, [{@value, -qty}, {@reserved, -qty}])
    :ets.insert(Store.touched_table(), {key})
    :ok
  end

  defp reserve_pending(key, qty) do
    ensure_seeded(key)
    [new, _reserved] = :ets.update_counter(table(), key, [{@value, qty}, {@reserved, qty}])
    :ets.insert(Store.touched_table(), {key})
    new
  end

  @doc """
  Releases a previously reserved `qty` (rollback on a failed function).

  `on` is the day the reservation was counted against. Without it the day
  history is decremented from the clock — so work that started at 23:59:59 and
  gave up a second later took its release out of the *next* day, leaving one
  day permanently over-counted and the other under. The period counter was
  taught this; the day bucket beside it was not.
  """
  @spec release(String.t(), atom(), integer(), DateTime.t(), Date.t() | nil) :: :ok
  def release(tenant_key, feature, qty, period_start, on \\ nil) do
    bump({tenant_key, feature, period_start}, -qty)
    bump_history(tenant_key, feature, -qty, on || Clock.today())
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
    |> :ets.match({{tenant_key, :"$1", period_start}, :"$2", :_, :_, :_, :_})
    |> Map.new(fn [feature, value] -> {feature, value} end)
  end

  @doc "Returns `date => value` for a feature's warm day buckets (no database access)."
  @spec warm_day_values(String.t(), atom()) :: %{Date.t() => integer()}
  def warm_day_values(tenant_key, feature) do
    table()
    |> :ets.match({{tenant_key, feature, {:day, :"$1"}}, :"$2", :_, :_, :_, :_})
    |> Map.new(fn [date, value] -> {date, value} end)
  end

  @doc """
  Atomically takes and zeroes a pending column, returning the delta accumulated
  since the last take. Concurrent bumps between the read and the zeroing are
  preserved (the column is decremented by the amount read, not set to zero).
  Cold keys yield `0`.
  """
  @spec take_pending(key(), pending()) :: integer()
  def take_pending(key, kind) do
    pos = pos(kind)

    if :ets.member(table(), key) do
      delta = :ets.update_counter(table(), key, {pos, 0})
      :ets.update_counter(table(), key, {pos, -delta})
      delta
    else
      0
    end
  end

  # `restore_pending/2` lived here until build unit 03b removed it (open
  # finding C8). It put a taken flush delta back so the next flush would retry
  # it, and nothing in `lib/` had called it since 0.4.0, when a failed flush
  # started keeping the immutable batch in ETS and retrying that instead. There
  # is no delta to put back any more.

  # Applies a durable event's quantity to this node's in-memory view.
  #
  # It deliberately mirrors `apply_remote/2` and not `bump/2`. `value` and
  # `pending_gossip` move, so `AuroraMeter.usage/2` and other nodes see the
  # number; `pending_flush` does not, and the key is NOT marked dirty. That is
  # what keeps a projected quantity out of `Store.snapshot_flush_batch/0`, out
  # of `Storage.flush_batch/3` and therefore out of `aurora_meter_counters`
  # (I08). A durable event is already committed to `aurora_meter_events`;
  # flushing it again would be the same usage counted twice, once as a fact and
  # once as a buffered count.
  #
  # Cold keys are skipped: a cold key seeds from durable state on its first
  # read, which already includes this event. `@remote` is not written, because
  # this node's own database read (`Storage.load_event_total/3`) already covers
  # it.
  #
  # Internal, and deliberately not public: hosts never touch ETS rows
  # (`api-change-map.md` section 5).
  # A NEGATIVE delta is a correction (build unit 03e), and it is the one case
  # this function has to do more than add. `:ets.update_counter/3` has no floor,
  # so a node whose ETS row was seeded after the original was recorded elsewhere
  # would show a negative advisory usage.
  #
  # The floor is the four-element form `{position, increment, threshold,
  # set_value}`, which is decided inside the same atomic operation as the
  # increment. A pre-read could not do it: two corrections of two different
  # originals landing on one key each read a value that the other has not yet
  # reduced, and the second one's subtraction takes the row negative and leaves
  # it there. The decision to re-seat is then taken from the value the update
  # RETURNS, which is the only reading that is certainly this update's own.
  #
  # Zero is the trigger rather than "the clamp fired", because the two are the
  # same answer: a key that a correction has taken to zero is a key whose
  # durable total is what it should be showing, and re-seating from that total
  # is not merely non-negative but correct. The cost is one database read on a
  # correction that reaches zero, which is rare and is not a hot path.
  #
  # `pending_gossip` takes the raw delta: it is a delta and not a count, and
  # flooring it would tell every peer that a reduction did not happen.
  @doc false
  @spec apply_projection(key(), integer()) :: :ok | :cold
  def apply_projection(key, qty) do
    cond do
      not :ets.member(table(), key) -> :cold
      qty >= 0 -> add_projection(key, qty)
      true -> subtract_projection(key, qty)
    end
  end

  defp add_projection(key, qty) do
    :ets.update_counter(table(), key, [{@value, qty}, {@pending_gossip, qty}])
    :ets.insert(Store.touched_table(), {key})
    :ok
  end

  defp subtract_projection(key, qty) do
    [value, _gossip] =
      :ets.update_counter(table(), key, [{@value, qty, 0, 0}, {@pending_gossip, qty}])

    :ets.insert(Store.touched_table(), {key})

    if value == 0, do: reseat(key)

    :ok
  end

  defp reseat(key) do
    Logger.debug(fn ->
      "AuroraMeter: a correction took the in-memory counter for #{inspect(key)} to zero, so it " <>
        "was re-seated from the durable total. The durable total is authoritative either way " <>
        "(AuroraMeter.Events.total/3)."
    end)

    rebase(key, stored_value(key) || 0, :gossip)
  end

  @doc """
  Applies a delta received from another node to this node's view. Only the
  value moves: the delta is not ours to flush or re-gossip. The key is marked
  touched so local LiveViews see the change. Cold keys are skipped (they seed
  from the database on first read, which already contains every flushed delta).
  """
  @spec apply_remote(key(), integer()) :: :ok | :cold
  def apply_remote(key, delta) do
    if :ets.member(table(), key) do
      # `@remote` as well as `@value`: another node's delta moves this node's
      # view without moving the database, and it is gossiped from the hot path
      # *before* that node flushes it. Anything reasoning about what the
      # database holds has to know that happened — see `remote_since_rebase/1`.
      :ets.update_counter(table(), key, [{@value, delta}, {@remote, delta}])
      :ets.insert(Store.touched_table(), {key})
      :ok
    else
      :cold
    end
  end

  @doc """
  How much of this key's value came from other nodes since the last rebase.

  Zero means `base/1` really is what this node believes the database holds;
  anything else means it is that plus deltas whose own nodes may not have
  written them yet.
  """
  @spec remote_since_rebase(key()) :: non_neg_integer()
  def remote_since_rebase(key) do
    case :ets.lookup(table(), key) do
      [{^key, _value, _pending_flush, _gossip, remote, _reserved}] -> remote
      [] -> 0
    end
  end

  @doc """
  Re-bases this node's view on an authoritative database total: `value`
  becomes `total + pending_flush`. Applied as a delta against a snapshot, so a
  bump that lands mid-rebase is kept exactly. Cold keys are skipped.

  `source` says where the total came from, and only `:flush` — this node's own
  write, which read the row back — clears `remote`. A total announced by
  another node is a database total *that node* saw, and this node may have
  applied gossiped deltas since; clearing `remote` for one of those told
  `remote_since_rebase/1` the view had not moved when it had, which is the one
  question the flusher asks before deciding whether a failed write landed.
  """
  @spec rebase(key(), integer(), :flush | :gossip) :: :ok | :cold
  def rebase(key, total, source \\ :flush) do
    case :ets.lookup(table(), key) do
      [{^key, value, pending_flush, _gossip, remote, reserved}] ->
        clear_remote = if source == :flush, do: -remote, else: 0

        :ets.update_counter(table(), key, [
          {@value, total + pending_flush + reserved - value},
          {@remote, clear_remote}
        ])

        :ets.insert(Store.touched_table(), {key})
        :ok

      [] ->
        :cold
    end
  end

  # Re-seats a warm events-source key on the total a newly activated projection
  # generation holds (build unit 03d).
  #
  # `rebase/3` with `:flush` and not `:gossip`, and the distinction matters:
  # `:flush` clears `remote`, which is what "this node has just read the
  # authoritative total, so every peer delta it already contains is accounted
  # for" means. `:gossip` would leave `remote` standing and the next reader of
  # `remote_since_rebase/1` would be told this node is carrying peer deltas the
  # database does not yet have, which after an activation is false.
  #
  # `pending_flush` is always zero for an events-source key (03c, I08), so
  # `rebase/3`'s `total + pending_flush + reserved` is `total + reserved`: a
  # reservation taken under `with_quota/4` survives the re-seat, which it must,
  # because it is work that is still running.
  #
  # A cold key is left alone and answers `:cold`: it seeds from
  # `Storage.load_event_total/3` on its first read, and that already reads the
  # new generation.
  @doc false
  @spec rehydrate(key()) :: :ok | :cold
  def rehydrate(key), do: rebase(key, stored_value(key) || 0, :flush)

  @doc "This node's base for a key: what it believes the database holds (`value - pending_flush`)."
  @spec base(key()) :: integer() | nil
  def base(key) do
    case :ets.lookup(table(), key) do
      [{^key, value, pending_flush, _gossip, _remote, reserved}] ->
        value - pending_flush - reserved

      [] ->
        nil
    end
  end

  # Seeds a counter row at a known value without reading storage.
  #
  # Internal, `@doc false`, and it exists so that nothing outside this module
  # has to know the row's shape. `mix aurora_meter.bench` warmed its keys with
  # `:ets.insert(Store.counters_table(), {key, 0, 0, 0})`, a four-element tuple
  # that was correct for 0.3 and has been wrong since 0.4.0 added `remote` and
  # `reserved`. `ensure_seeded/1` finds the key present and does not repair it,
  # so the increments succeeded and the first `value/3` raised `MatchError` on
  # the six-element pattern in `read/1` (`open-findings.md` C7). Widening the
  # tuple at the call site would only have moved the next drift; the duplicate
  # definition is the defect, so the row is built here, once, by the same
  # private function `ensure_seeded/1` uses.
  @doc false
  @spec warm(key(), integer()) :: :ok
  def warm(key, value \\ 0) do
    :ets.insert(table(), row(key, value))
    :ok
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

    [new, _pending_flush, _pending_gossip] =
      :ets.update_counter(table(), key, [
        {@value, qty},
        {@pending_flush, qty},
        {@pending_gossip, qty}
      ])

    mark_dirty(key)
    new
  end

  @spec bump_history(String.t(), atom(), integer(), Date.t()) :: :ok
  defp bump_history(tenant_key, feature, qty, on) do
    if Config.history?(), do: bump({tenant_key, feature, {:day, on}}, qty)
    :ok
  end

  @spec read(key()) :: integer()
  defp read(key) do
    ensure_seeded(key)
    [{^key, val, _, _, _, _}] = :ets.lookup(table(), key)
    val
  end

  @spec keys(atom()) :: [key()]
  defp keys(table), do: table |> :ets.tab2list() |> Enum.map(&elem(&1, 0))

  @spec ensure_seeded(key()) :: :ok
  defp ensure_seeded(key) do
    if :ets.member(table(), key) do
      :ok
    else
      :ets.insert_new(table(), row(key, stored_value(key) || 0))
      :ok
    end
  end

  # The one definition of a counter row. `warm/2` and `ensure_seeded/1` are its
  # only callers, which is the whole point: C7 was a second definition.
  @spec row(key(), integer()) :: tuple()
  defp row(key, value), do: {key, value, 0, 0, 0, 0}

  # Where a cold key gets its first value. A day bucket comes from the history
  # table; a period counter comes from whichever source the feature reports
  # from. The indirection through `Config.feature_source/1` is the one place
  # that decision is taken, so build unit 03c can change what feeds it without
  # touching the hot path.
  @spec stored_value(key()) :: integer() | nil
  defp stored_value({tenant_key, feature, {:day, date}}),
    do: Storage.load_history(tenant_key, feature, date)

  defp stored_value({tenant_key, feature, period_start}) do
    case Config.feature_source(feature) do
      :events -> event_total(tenant_key, feature, period_start)
      _buffered -> Storage.load_counter(tenant_key, feature, period_start)
    end
  end

  @spec event_total(String.t(), atom(), DateTime.t()) :: integer() | nil
  defp event_total(tenant_key, feature, period_start) do
    case Storage.load_event_total(tenant_key, feature, period_start) do
      {:ok, %{quantity: quantity}} -> quantity
      {:error, _unsupported} -> nil
    end
  end

  defp pos(:flush), do: @pending_flush
  defp pos(:gossip), do: @pending_gossip

  @spec table() :: atom()
  defp table, do: Store.counters_table()
end
