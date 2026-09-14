defmodule AuroraMeter.ClusterTest do
  @moduledoc false
  use AuroraMeter.DataCase, async: false
  use ExUnitProperties

  alias AuroraMeter.Cluster
  alias AuroraMeter.Counter
  alias AuroraMeter.Flusher
  alias AuroraMeter.LiveView
  alias AuroraMeter.Period
  alias AuroraMeter.Storage
  alias AuroraMeter.Test, as: MeterTest

  @peer :peer@test

  defp period(tenant), do: Period.current(tenant).start

  describe "gossip from another node" do
    test "moves this node's view without making the delta ours to flush" do
      tenant = unique_tenant()
      AuroraMeter.track(tenant, :ops, 2)

      MeterTest.simulate_node(@peer, [{tenant, :ops, 5}])
      assert AuroraMeter.usage(tenant, :ops) == 7

      # Only our own 2 reach the database: the peer flushes its own 5.
      {:ok, _} = Flusher.flush()
      assert Storage.load_counter(tenant, :ops, period(tenant)) == 2
      # After the flush we re-base on the database total (2) plus nothing
      # pending; the peer's unflushed 5 is no longer in our view until it
      # flushes and announces, which is the documented convergence path.
      assert AuroraMeter.usage(tenant, :ops) == 2
    end

    test "is ignored for cold keys, which seed from the database instead" do
      tenant = unique_tenant()
      MeterTest.simulate_node(@peer, [{tenant, :ops, 9}])
      assert AuroraMeter.usage(tenant, :ops) == 0
    end

    test "marks the key touched so local LiveViews see it" do
      tenant = unique_tenant()
      :ok = LiveView.subscribe(tenant)
      AuroraMeter.track(tenant, :ops, 1)
      :ok = MeterTest.broadcast!()
      assert_receive {:aurora_meter, :usage, %{feature: :ops, value: 1}}

      MeterTest.simulate_node(@peer, [{tenant, :ops, 4}])
      :ok = MeterTest.broadcast!()
      assert_receive {:aurora_meter, :usage, %{feature: :ops, value: 5}}
    end

    test "messages from this node are ignored" do
      tenant = unique_tenant()
      AuroraMeter.track(tenant, :ops, 1)
      MeterTest.simulate_node(node(), [{tenant, :ops, 100}])
      assert AuroraMeter.usage(tenant, :ops) == 1
    end
  end

  describe "total announcements from another node" do
    test "re-base the view on the total plus our unflushed increments" do
      tenant = unique_tenant()
      AuroraMeter.track(tenant, :ops, 3)

      MeterTest.simulate_flush(@peer, [{tenant, :ops, 40}])
      assert AuroraMeter.usage(tenant, :ops) == 43
    end

    test "I05 a totals announcement never moves a view backwards" do
      tenant = unique_tenant()
      AuroraMeter.track(tenant, :ops, 3)
      {:ok, _} = Flusher.flush()
      assert Counter.base({tenant, :ops, period(tenant)}) == 3

      MeterTest.simulate_flush(@peer, [{tenant, :ops, 1}])
      assert AuroraMeter.usage(tenant, :ops) == 3
    end
  end

  describe "two writers" do
    test "flushes add up in the database instead of overwriting" do
      tenant = unique_tenant()
      p = period(tenant)

      # The other node flushed 10 straight into the database.
      {:ok, _} =
        Storage.add_counters([%{tenant_key: tenant, feature: :ops, period_start: p, delta: 10}])

      # We were already warm with our own 4 (seeded before the peer's write).
      AuroraMeter.track(tenant, :ops, 4)
      {:ok, _} = Flusher.flush()

      assert Storage.load_counter(tenant, :ops, p) == 14
      # And our own view has been re-based on the true total.
      assert AuroraMeter.usage(tenant, :ops) == 14

      # A second flush with nothing pending changes nothing.
      {:ok, 0} = Flusher.flush()
      assert Storage.load_counter(tenant, :ops, p) == 14
    end

    test "negative deltas (reserve rollback, release) round-trip" do
      tenant = unique_tenant()
      p = period(tenant)
      AuroraMeter.track(tenant, :ops, 5)
      {:ok, _} = Flusher.flush()

      Counter.release(tenant, :ops, 2, p)
      {:ok, _} = Flusher.flush()
      assert Storage.load_counter(tenant, :ops, p) == 3
      assert AuroraMeter.usage(tenant, :ops) == 3
    end

    test "a seed that races another node's flush heals on the announcement" do
      tenant = unique_tenant()
      p = period(tenant)

      # We seed cold (0), the peer then flushes 7 and announces the total.
      assert AuroraMeter.usage(tenant, :ops) == 0

      {:ok, _} =
        Storage.add_counters([%{tenant_key: tenant, feature: :ops, period_start: p, delta: 7}])

      MeterTest.simulate_flush(@peer, [{tenant, :ops, 7}])
      assert AuroraMeter.usage(tenant, :ops) == 7
    end

    property "I05 final database total equals the sum of all deltas and the local view matches it" do
      check all(
              local <- list_of(integer(-3..10), min_length: 1, max_length: 12),
              remote <- list_of(integer(0..10), max_length: 8),
              max_runs: 20
            ) do
        tenant = unique_tenant()
        p = period(tenant)
        AuroraMeter.track(tenant, :ops, 0)

        for d <- local do
          if d >= 0,
            do: AuroraMeter.track(tenant, :ops, d),
            else: Counter.release(tenant, :ops, -d, p)

          if rem(d, 4) == 0, do: {:ok, _} = Flusher.flush()
        end

        # The other node flushes its deltas and, as a real node does, announces
        # the resulting total.
        for d <- remote do
          {:ok, [%{value: total}]} =
            Storage.add_counters([
              %{tenant_key: tenant, feature: :ops, period_start: p, delta: d}
            ])

          MeterTest.simulate_flush(@peer, [{tenant, :ops, total}])
        end

        {:ok, _} = Flusher.flush()
        expected = Enum.sum(local) + Enum.sum(remote)

        # A row that was never written reads as nil, and that is the right
        # storage-level answer: when the deltas cancel out there is nothing to
        # persist, and writing a zero row would be amplification for no gain.
        # What must hold is the *total*, which is what callers see.
        assert (Storage.load_counter(tenant, :ops, p) || 0) == expected
        assert AuroraMeter.usage(tenant, :ops) == expected
      end
    end
  end

  describe "when the database write fails" do
    defmodule FailingStorage do
      @moduledoc false
      @behaviour AuroraMeter.Storage

      defdelegate upsert_counters(rows), to: AuroraMeter.Storage.Ecto
      defdelegate load_counter(t, f, p), to: AuroraMeter.Storage.Ecto
      defdelegate upsert_history(rows), to: AuroraMeter.Storage.Ecto
      defdelegate load_history(t, f, d), to: AuroraMeter.Storage.Ecto
      defdelegate load_history_range(t, f, from, to), to: AuroraMeter.Storage.Ecto
      defdelegate get_subscription(t), to: AuroraMeter.Storage.Ecto
      defdelegate put_subscription(attrs), to: AuroraMeter.Storage.Ecto
      defdelegate insert_events(rows), to: AuroraMeter.Storage.Ecto
      defdelegate stream_counters(p), to: AuroraMeter.Storage.Ecto
      def add_counters(_rows), do: raise("database down")
      def add_history(_rows), do: raise("database down")
      def flush_batch(_id, _rows, _history), do: raise("database down")
    end

    test "the deltas are kept pending and flushed on the next attempt" do
      tenant = unique_tenant()
      p = period(tenant)
      AuroraMeter.track(tenant, :ops, 6)

      Application.put_env(:aurora_meter, :storage, FailingStorage)
      on_exit(fn -> Application.delete_env(:aurora_meter, :storage) end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, _} = Flusher.flush()
        end)

      assert log =~ "flush failed"
      assert AuroraMeter.usage(tenant, :ops) == 6
      assert Storage.load_counter(tenant, :ops, p) == nil

      Application.delete_env(:aurora_meter, :storage)
      {:ok, n} = Flusher.flush()
      assert n >= 1
      assert Storage.load_counter(tenant, :ops, p) == 6
    end
  end

  describe "when the database write commits and then reports failure" do
    defmodule TimingOutStorage do
      @moduledoc false
      @behaviour AuroraMeter.Storage

      alias AuroraMeter.Storage.Ecto, as: EctoStorage

      def flush_batch(id, rows, history) do
        EctoStorage.flush_batch(id, rows, history)
        exit(:timeout)
      end

      defdelegate upsert_counters(rows), to: EctoStorage
      defdelegate load_counter(t, f, p), to: EctoStorage
      defdelegate upsert_history(rows), to: EctoStorage
      defdelegate load_history(t, f, d), to: EctoStorage
      defdelegate load_history_range(t, f, from, to), to: EctoStorage
      defdelegate get_subscription(t), to: EctoStorage
      defdelegate put_subscription(attrs), to: EctoStorage
      defdelegate insert_events(rows), to: EctoStorage
      defdelegate stream_counters(p), to: EctoStorage

      # Exactly the shape of a statement that times out client-side: the row
      # is written, and then the caller is told the write failed.
      def add_counters(rows) do
        EctoStorage.add_counters(rows)
        exit(:timeout)
      end

      def add_history(rows) do
        EctoStorage.add_history(rows)
        exit(:timeout)
      end
    end

    test "a node that has heard gossip retries its batch without duplicating usage" do
      tenant = unique_tenant()
      p = period(tenant)
      AuroraMeter.track(tenant, :ops, 6)

      # Another node's traffic, gossiped before it has been written anywhere.
      Cluster.apply(:deltas, "other-node", [{{tenant, :ops, p}, 5}])

      Application.put_env(:aurora_meter, :storage, TimingOutStorage)
      on_exit(fn -> Application.delete_env(:aurora_meter, :storage) end)

      log = ExUnit.CaptureLog.capture_log(fn -> assert {:error, _} = Flusher.flush() end)
      assert log =~ "flush failed"

      Application.delete_env(:aurora_meter, :storage)
      {:ok, _n} = Flusher.flush()

      # Gossip is not evidence of a database commit. The receipt proves our
      # six landed, so retrying the same batch leaves exactly six persisted.
      assert Storage.load_counter(tenant, :ops, p) == 6
    end

    test "gossip marks the key as no longer speaking for the database" do
      # The signal the check above rests on: once another node's delta has been
      # applied, this node's base is that node's word for something it may not
      # have written yet, and a rebase on a real database total clears it.
      tenant = unique_tenant()
      p = period(tenant)
      key = {tenant, :ops, p}
      AuroraMeter.track(tenant, :ops, 6)

      assert Counter.remote_since_rebase(key) == 0

      Cluster.apply(:deltas, "other-node", [{key, 5}])
      assert Counter.remote_since_rebase(key) == 5

      Counter.rebase(key, 11)
      assert Counter.remote_since_rebase(key) == 0
    end

    test "the delta is not put back, so the next flush cannot bill it twice" do
      tenant = unique_tenant()
      p = period(tenant)
      AuroraMeter.track(tenant, :ops, 6)

      Application.put_env(:aurora_meter, :storage, TimingOutStorage)
      on_exit(fn -> Application.delete_env(:aurora_meter, :storage) end)

      log = ExUnit.CaptureLog.capture_log(fn -> assert {:error, _} = Flusher.flush() end)
      assert log =~ "flush failed"

      # The write really did land.
      assert Storage.load_counter(tenant, :ops, p) == 6

      Application.delete_env(:aurora_meter, :storage)
      {:ok, _n} = Flusher.flush()

      # The receipt makes this retry a read of the current totals.
      assert Storage.load_counter(tenant, :ops, p) == 6
      assert AuroraMeter.usage(tenant, :ops) == 6
    end
  end

  describe "configuration" do
    test "the cluster process is supervised and subscribed by default" do
      assert is_pid(Process.whereis(Cluster))
      assert Cluster.enabled?()
      assert Cluster.topic() == "aurora_meter:cluster"
    end

    test "publishing with sync off is a no-op" do
      Application.put_env(:aurora_meter, :cluster_sync, false)
      on_exit(fn -> Application.delete_env(:aurora_meter, :cluster_sync) end)

      Phoenix.PubSub.subscribe(AuroraMeter.TestPubSub, Cluster.topic())
      assert :ok = Cluster.publish_deltas([{{"t", :ops, ~U[2026-07-01 00:00:00Z]}, 1}])
      refute_receive {:aurora_meter, :deltas, _, _}, 50
    end

    test "gossip carries deltas for period and day keys with this node as origin" do
      tenant = unique_tenant()
      Phoenix.PubSub.subscribe(AuroraMeter.TestPubSub, Cluster.topic())

      AuroraMeter.track(tenant, :ops, 3)
      :ok = MeterTest.broadcast!()

      assert_receive {:aurora_meter, :deltas, origin, deltas}
      assert origin == node()
      assert {{tenant, :ops, period(tenant)}, 3} in deltas

      assert Enum.any?(deltas, fn
               {{t, :ops, {:day, %Date{}}}, 3} -> t == tenant
               _ -> false
             end)

      # Nothing new: no second gossip.
      :ok = MeterTest.broadcast!()
      refute_receive {:aurora_meter, :deltas, _, _}, 50
    end
  end
end
