defmodule AuroraMeter.StoreGaugeTest do
  @moduledoc """
  `[:aurora_meter, :store, :gauge]`: what is buffered, and how old it is.

  Every assertion here is driven by forcing a tick with
  `AuroraMeter.Store.emit_gauge/0` and by moving a frozen clock, never by
  sleeping. A test that waits for a real interval measures the scheduler.

  `async: false` because the dirty set and the counters table are node-wide ETS
  tables, so a concurrent module's increments would land in this module's
  counts.
  """
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Flusher
  alias AuroraMeter.Store
  alias AuroraMeter.Telemetry
  alias AuroraMeter.Test.Config
  alias AuroraMeter.Test.Kill
  alias AuroraMeter.Test.RefusingStorage

  @event [:aurora_meter, :store, :gauge]

  setup do
    # Drain whatever an earlier module left buffered, so `dirty_keys` counts
    # this test's increments and not the suite's history.
    {:ok, _} = Flusher.flush()
    :ok
  end

  test "I01 store.gauge reports dirty_keys equal to the dirty table size, and 0 with none" do
    attach()

    assert %{dirty_keys: 0, oldest_pending_age_ms: 0, pending_batch_age_ms: 0} = sample()

    tenant = unique_tenant("gauge")

    Config.with_config([{:aurora_meter, :history, false}], fn ->
      for n <- 1..10, do: AuroraMeter.track(tenant, :"gauge_feature_#{n}", 1)
    end)

    assert :ets.info(Store.dirty_table(), :size) == 10

    measurements = sample()
    assert measurements.dirty_keys == 10
    assert measurements.counter_keys >= 10
  end

  test "I01 oldest_pending_age_ms is zero while the dirty set is empty and grows once it is not" do
    attach()
    tenant = unique_tenant("gaugeage")

    # `with_config` outside and `with_clock` inside, never the other way round:
    # both serialise on the same token, and `with_clock` detects that the caller
    # already holds it (X51) while `with_config` would queue behind itself and
    # deadlock.
    Config.with_config([{:aurora_meter, :history, false}], fn ->
      AuroraMeter.Test.with_clock(~U[2026-09-16 00:00:00.000000Z], fn ->
        assert sample().oldest_pending_age_ms == 0

        AuroraMeter.track(tenant, :gauge_age, 1)

        # Still zero, and for a reason worth stating: the measurement is time
        # since the set was last **observed** empty, and under a frozen clock no
        # time has passed since the sample above observed exactly that. It is
        # not "the first tick resets the clock".
        assert sample().oldest_pending_age_ms == 0

        AuroraMeter.Test.travel(90, :second)
        assert sample().oldest_pending_age_ms == 90_000

        # Draining it resets the measurement rather than leaving it high: the
        # next tick observes the set empty and moves the mark.
        {:ok, _} = Flusher.flush()
        assert sample().oldest_pending_age_ms == 0

        # And the half the criterion names: time passes while the set stays
        # non-empty, and the very next sample after the increment is already
        # non-zero, because the mark is where the set was last seen clear.
        AuroraMeter.track(tenant, :gauge_age_2, 1)
        AuroraMeter.Test.travel(7, :second)

        assert sample().oldest_pending_age_ms == 7_000,
               "the age is measured from the last moment the buffer was known to be " <>
                 "clear, not from the moment somebody first noticed it was not"

        {:ok, _} = Flusher.flush()
      end)
    end)
  end

  test "I01 pending_batch_age_ms grows while a batch is retained and returns to zero on commit" do
    attach()
    tenant = unique_tenant("gaugebatch")

    Config.with_config(
      [
        {:aurora_meter, :history, false},
        {:aurora_meter, :storage, RefusingStorage}
      ],
      fn ->
        AuroraMeter.Test.with_clock(~U[2026-09-16 01:00:00.000000Z], fn ->
          AuroraMeter.track(tenant, :gauge_batch, 5)

          RefusingStorage.refuse(1)
          assert {:error, :refused_by_test} = Flusher.flush()

          assert sample().pending_batch_age_ms == 0
          assert sample().pending_batch_items == 1

          AuroraMeter.Test.travel(45, :second)
          assert sample().pending_batch_age_ms == 45_000

          assert {:ok, 1} = Flusher.flush()

          after_commit = sample()
          assert after_commit.pending_batch_age_ms == 0
          assert after_commit.pending_batch_items == 0
        end)
      end
    )
  end

  test "I01 pending_batch_age_ms is zero for a batch map carried across a release with no taken_at_ms" do
    attach()
    tenant = unique_tenant("gaugeold")

    Config.with_config([{:aurora_meter, :history, false}], fn ->
      AuroraMeter.track(tenant, :gauge_old, 3)
      batch = Store.snapshot_flush_batch()

      # Exactly what a hot upgrade leaves behind: a batch snapshotted by a
      # release that did not write the key. Inventing an age for it would put a
      # made-up number on a graph an operator is about to act on.
      :ets.insert(Store.flush_batches_table(), {:pending, Map.delete(batch, :taken_at_ms)})

      assert sample().pending_batch_age_ms == 0
      assert sample().pending_batch_items == 1

      {:ok, _} = Flusher.flush()
    end)
  end

  test "M5 the gauge tick does not materialise the dirty table" do
    attach()
    tenant = unique_tenant("gaugecost")

    Config.with_config([{:aurora_meter, :history, false}], fn ->
      for n <- 1..2_000, do: AuroraMeter.track(tenant, :"gauge_cost_#{n}", 1)

      # `Counter.dirty_keys/0` calls `:ets.tab2list/1`, so a tick that used it
      # would allocate the whole table. Reductions in the Store process are the
      # measurement, not wall clock: a wall-clock bound on a shared CI machine
      # is a flake generator, and what is being caught is an algorithm change.
      before = reductions()
      :ok = Store.emit_gauge()
      after_tick = reductions()

      assert_receive {:gauge, measurements, _meta}, 500
      assert measurements.dirty_keys == 2_000

      assert after_tick - before < 2_000,
             "the gauge tick used #{after_tick - before} reductions over a 2,000 key dirty " <>
               "set; a constant-time tick costs a few hundred, and anything scaling with " <>
               "the table is a full scan on the flush path"

      {:ok, _} = Flusher.flush()
    end)
  end

  test "a raising gauge handler does not stop the Store or its timer" do
    name = "gauge-raiser-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      name,
      @event,
      fn _event, _measurements, _meta, _config -> raise "handler blew up" end,
      nil
    )

    # `:telemetry` detaches a raising handler itself, so this is belt and
    # braces: a handler left attached by a test is a leak into every module
    # that runs after it, which is G08 bullet 2's other half.
    on_exit(fn -> :telemetry.detach(name) end)

    pid = Process.whereis(Store)

    # `:telemetry` detaches a handler that raises and the Store survives it,
    # which is the behaviour a host depends on: one bad handler must not cost
    # the node its ETS tables.
    :ok = Store.emit_gauge()
    :ok = Store.emit_gauge()

    assert Process.whereis(Store) == pid
    assert Process.alive?(pid)
  end

  test "emit_gauges/0 emits the store gauge on demand for a host running its own scheduler" do
    attach()
    assert :ok = Telemetry.emit_gauges()
    assert_receive {:gauge, %{dirty_keys: _}, %{node: node}}, 500
    assert node == node()
  end

  test "the gauge timer arms itself at boot and re-arms after each tick" do
    # The only assertion in this file that needs a real timer. It restarts the
    # Store so `init/1` reads the interval, which is the arming path a host
    # actually takes; forcing a tick would prove the handler and not the boot.
    attach()

    Config.with_config([{:aurora_meter, :metrics_interval, 50}], fn ->
      pid = Process.whereis(Store)
      Process.exit(pid, :kill)
      Kill.await_restart!(Store, from: pid)

      # A timer that fires once proves `init/1` armed it; a second sample with no
      # further help proves `handle_info/2` re-arms. The values are asserted
      # too: a Store with no traffic reports an empty buffer and no age, which
      # is what an operator reads as "nothing is stuck".
      assert_receive {:gauge, first, _meta}, 2_000
      assert first.dirty_keys == 0
      assert first.oldest_pending_age_ms == 0
      assert first.pending_batch_age_ms == 0

      assert_receive {:gauge, _second, _meta}, 2_000
    end)

    # Back to the suite's `metrics_interval: 0`, without a second kill: the
    # supervisor allows three restarts in five seconds and a test that spends
    # two of them is a test that can take the tree down when it runs beside
    # `AuroraMeter.KillTest`. Replacing the interval in the running state is
    # enough, because `handle_info(:gauge, ...)` re-arms from the state it was
    # handed, so the tick already in flight is the last one.
    :sys.replace_state(Store, &%{&1 | gauge_interval: 0})

    # One tick may already be in the mailbox or in flight. Draining first is the
    # point: a `refute_receive` that consumed a sample from before the change
    # would be asserting the timer is off while it was still on.
    assert_receive {:gauge, _measurements, _meta}, 2_000
    drain()
    refute_receive {:gauge, _measurements, _meta}, 500
  end

  test "no gauge event is emitted at all when metrics_interval is zero" do
    attach()

    pid = Process.whereis(Store)
    assert AuroraMeter.Config.metrics_interval() == 0
    send(pid, :gauge)

    # The handler still emits when something sends the message, which is what
    # `emit_gauge/0` uses; what `0` removes is the timer that sends it.
    assert_receive {:gauge, _measurements, _meta}, 500
    refute_receive {:gauge, _measurements, _meta}, 300
  end

  defp attach do
    name = "gauge-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      name,
      @event,
      fn _event, measurements, meta, _config -> send(test, {:gauge, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(name) end)
  end

  defp sample do
    :ok = Store.emit_gauge()
    assert_receive {:gauge, measurements, %{node: _}}, 500
    measurements
  end

  defp drain do
    receive do
      {:gauge, _measurements, _meta} -> drain()
    after
      0 -> :ok
    end
  end

  defp reductions do
    {:reductions, count} = Process.info(Process.whereis(Store), :reductions)
    count
  end
end
