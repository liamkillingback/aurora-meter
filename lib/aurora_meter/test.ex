defmodule AuroraMeter.Test do
  @moduledoc """
  Helpers for testing an application that uses Aurora Meter.

      defmodule MyApp.MeterCase do
        use ExUnit.CaseTemplate

        using do
          quote do
            use AuroraMeter.Test, reset: true
          end
        end
      end

  `use AuroraMeter.Test` imports every function below. With `reset: true` the
  ETS tables are cleared before each test (see `reset!/0`, which requires
  `async: false`); with `sandbox: true` an `Ecto.Adapters.SQL.Sandbox` owner is
  started on the configured repo for tests that do not already have one.

  Set large `:flush_interval` / `:broadcast_interval` values in test config so
  the timers never fire mid-test, and drive them with `flush!/0` and
  `broadcast!/0`.

  Cross-node behaviour can be exercised on one node: `simulate_node/3` applies
  deltas as if another node had gossiped them, and `simulate_flush/2` applies
  totals as if another node had flushed.

  For the credit ledger, `fund!/3` and `drain!/1` put a tenant at a known
  balance without inventing references, and `credit_balance/1` reads it back.

  To make a time-dependent behaviour deterministic, freeze the clock with
  `with_clock/2` and move it with `travel/1` and `travel/2`. The fixed clock is
  a single named agent, so it is global to the node and every test that uses it
  must be `async: false`.
  """

  alias AuroraMeter.Broadcaster
  alias AuroraMeter.Clock.Fixed
  alias AuroraMeter.Cluster
  alias AuroraMeter.Config
  alias AuroraMeter.Credits
  alias AuroraMeter.Flusher
  alias AuroraMeter.Period
  alias AuroraMeter.Store
  alias AuroraMeter.Tenant
  alias Ecto.Adapters.SQL.Sandbox

  @doc false
  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      import AuroraMeter.Test

      if Keyword.get(opts, :sandbox, false), do: setup(:aurora_meter_checkout)
      if Keyword.get(opts, :reset, false), do: setup(:reset_aurora_meter)
    end
  end

  @doc """
  Clears every Aurora Meter ETS table: counters, dirty and touched sets, and
  the subscription cache. Unflushed usage is discarded; the database is not
  touched. Because the tables are global, only use this in `async: false`
  tests (or give each test a unique tenant instead, see `unique_tenant/1`).
  """
  @spec reset!() :: :ok
  def reset! do
    for table <- [
          Store.counters_table(),
          Store.dirty_table(),
          Store.touched_table(),
          Store.subscription_cache_table(),
          Store.flush_batches_table()
        ] do
      :ets.delete_all_objects(table)
    end

    :ok
  end

  @doc false
  def reset_aurora_meter(_context) do
    reset!()
    :ok
  end

  @doc "Flushes dirty counters to the database now; returns the number of keys persisted."
  @spec flush!() :: non_neg_integer()
  def flush! do
    {:ok, count} = Flusher.flush()
    count
  end

  @doc "Broadcasts touched counters to subscribed LiveViews (and gossips deltas) now."
  @spec broadcast!() :: :ok
  def broadcast!, do: Broadcaster.broadcast_now()

  @doc "A process-unique tenant key, so tests can share the global ETS tables safely."
  @spec unique_tenant(String.t()) :: String.t()
  def unique_tenant(prefix \\ "org"), do: "#{prefix}_#{System.unique_integer([:positive])}"

  @doc """
  Starts an `Ecto.Adapters.SQL.Sandbox` owner on the configured repo (shared
  unless the test is async) and stops it on exit. Use only when your own case
  template does not already do this.
  """
  @spec checkout(map()) :: :ok
  def checkout(tags \\ %{}) do
    pid = Sandbox.start_owner!(Config.repo(), shared: not tags[:async])
    ExUnit.Callbacks.on_exit(fn -> Sandbox.stop_owner(pid) end)
    :ok
  end

  @doc false
  def aurora_meter_checkout(tags), do: checkout(tags)

  @doc """
  Applies `deltas` (`[{tenant, feature, delta}]`) as if node `origin` had
  gossiped them: this node's view of each counter moves by the delta, exactly
  as it would in a cluster. `period_start` defaults to the tenant's current
  period. Only warm counters are affected, as in production; read the counter
  first if you need it seeded.
  """
  @spec simulate_node(node(), [{term(), atom(), integer()}], DateTime.t() | nil) :: :ok
  def simulate_node(origin, deltas, period_start \\ nil) do
    Cluster.apply(:deltas, origin, keyed(deltas, period_start))
  end

  @doc """
  Applies `totals` (`[{tenant, feature, total}]`) as if node `origin` had
  flushed and announced them: this node re-bases each warm counter on the total
  plus its own unflushed increments.
  """
  @spec simulate_flush(node(), [{term(), atom(), integer()}], DateTime.t() | nil) :: :ok
  def simulate_flush(origin, totals, period_start \\ nil) do
    Cluster.apply(:totals, origin, keyed(totals, period_start))
  end

  @doc """
  Grants `amount` micro-dollars to `tenant` as an `:adjustment` with a unique
  reference (so it never collides with an earlier grant), returning the entry.
  Any `AuroraMeter.Credits.grant/3` option can be overridden in `opts`.

      fund!(org, Money.from_cents(1_000))
      fund!(org, 500_000, category: :promotional, expires_at: tomorrow)
  """
  @spec fund!(term(), pos_integer(), keyword()) :: Credits.txn()
  def fund!(tenant, amount, opts \\ []) do
    opts =
      Keyword.merge(
        [reference: "fund:#{System.unique_integer([:positive])}", category: :adjustment],
        opts
      )

    {:ok, txn} = Credits.grant(tenant, amount, opts)
    txn
  end

  @doc """
  Debits everything `tenant` has available (nothing when the available balance
  is zero or negative), returning the amount drained.
  """
  @spec drain!(term()) :: non_neg_integer()
  def drain!(tenant) do
    case Credits.available(tenant) do
      available when available > 0 ->
        {:ok, _txn} =
          Credits.debit(tenant, available, "drain:#{System.unique_integer([:positive])}")

        available

      _nothing ->
        0
    end
  end

  @doc "The tenant's credit balance snapshot; see `AuroraMeter.Credits.balance/1`."
  @spec credit_balance(term()) :: Credits.balance()
  def credit_balance(tenant), do: Credits.balance(tenant)

  @doc """
  Runs `fun` with the library's clock frozen at `instant`.

  Installs `AuroraMeter.Clock.Fixed` under the `clock:` key, starts it at
  `instant`, runs `fun`, then stops the agent and restores the previous
  configuration. Restoration and the stop both run on a raise as well as on a
  normal return, so one failing test cannot leave the next one frozen.

  Inside the block, move the clock with `travel/1` and `travel/2`.

      with_clock(~U[2026-01-31 23:59:59.999999Z], fn ->
        assert AuroraMeter.period(org).start == ~U[2026-01-01 00:00:00Z]
        travel(1, :microsecond)
        assert AuroraMeter.period(org).start == ~U[2026-02-01 00:00:00Z]
      end)

  The fixed clock is global to the node: use it only in `async: false` tests.
  Because a frozen clock stamps every row with the same `inserted_at`, a test
  that writes several credit ledger rows and then pages `AuroraMeter.Credits.history/2`
  must `travel/2` between the writes; see `docs/testing.md`.
  """
  @spec with_clock(DateTime.t(), (-> result)) :: result when result: var
  def with_clock(%DateTime{} = instant, fun) when is_function(fun, 0) do
    serialise(fn ->
      # A previous run that was killed rather than unwound could have left the
      # agent behind. Stopping first makes the helper idempotent instead of
      # failing with :already_started on an unrelated test's mess.
      Fixed.stop()
      {:ok, _pid} = Fixed.start_link(instant: instant)

      try do
        fun.()
      after
        Fixed.stop()
      end
    end)
  end

  @doc "Moves the frozen clock to `instant`. Raises outside a `with_clock/2` block."
  @spec travel(DateTime.t()) :: :ok
  def travel(%DateTime{} = instant) do
    ensure_frozen!()
    Fixed.set(instant)
  end

  @doc """
  Moves the frozen clock by `amount` of `unit` (any unit `DateTime.add/3`
  accepts). Raises outside a `with_clock/2` block, so it cannot silently no-op.
  """
  @spec travel(integer(), Fixed.unit()) :: :ok
  def travel(amount, unit) when is_integer(amount) do
    ensure_frozen!()
    Fixed.advance(amount, unit)
  end

  # Serialises on the same token AuroraMeter.Test.Config uses, so a frozen clock
  # never overlaps another test's configuration region. That module is this
  # repository's own harness and ships in no archive, so a host calling
  # with_clock/2 from its own suite gets the same save and restore without it.
  defp serialise(fun) do
    # Module.concat/1 rather than the literal alias: this file is in lib/ and
    # the harness is in test/support, so a compile-time remote call to it would
    # warn (and warnings are errors) in every build that does not compile
    # test/support.
    lock = Module.concat([:AuroraMeter, :Test, :Config])

    if Code.ensure_loaded?(lock) and is_pid(Process.whereis(lock)) and lock.holder() != self() do
      lock.with_config([{:aurora_meter, :clock, Fixed}], fun)
    else
      # Either there is no harness (a host suite), or this process already holds
      # the configuration token. Acquiring it again would queue behind itself
      # and deadlock (open-findings.md X51), and it is unnecessary: the token is
      # exclusive, so the region this call sits inside is already serialised.
      previous = Application.fetch_env(:aurora_meter, :clock)
      Application.put_env(:aurora_meter, :clock, Fixed)

      try do
        fun.()
      after
        restore_clock(previous)
      end
    end
  end

  defp restore_clock({:ok, value}), do: Application.put_env(:aurora_meter, :clock, value)
  defp restore_clock(:error), do: Application.delete_env(:aurora_meter, :clock)

  defp ensure_frozen! do
    if Config.clock() != Fixed or not Fixed.running?() do
      raise RuntimeError,
            "AuroraMeter.Test.travel/1,2 needs a frozen clock. Wrap the work in " <>
              "AuroraMeter.Test.with_clock/2."
    end
  end

  defp keyed(entries, period_start) do
    Enum.map(entries, fn {tenant, feature, amount} ->
      key = Tenant.to_key(tenant)
      {{key, feature, period_start || Period.current!(tenant).start}, amount}
    end)
  end
end
