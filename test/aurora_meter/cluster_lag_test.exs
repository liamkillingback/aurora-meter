defmodule AuroraMeter.ClusterLagTest do
  @moduledoc """
  `[:aurora_meter, :cluster, :lag]`: node-local convergence state.

  True end to end gossip lag is not measurable without putting a timestamp in
  the wire format, and changing that format would make a new node's messages
  fall through an old node's catch-all clause during a rolling upgrade, which
  drops gossip silently for one flush interval. So this gauge reports what is
  locally observable and says so, and the tests here assert the three
  measurements it does report rather than a lag it cannot know.
  """
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Cluster
  alias AuroraMeter.Counter
  alias AuroraMeter.Flusher
  alias AuroraMeter.Period
  alias AuroraMeter.Store
  alias AuroraMeter.Test.Config

  @event [:aurora_meter, :cluster, :lag]

  setup do
    {:ok, _} = Flusher.flush()

    # An empty peer map per test, so `peers == 0` is a fact rather than a
    # function of the seed: the Cluster process is node-wide and these tests add
    # peers to it.
    #
    # `:sys.replace_state/2` and NOT a kill. Killing it restarts it, and the
    # supervisor's default intensity is three restarts in five seconds, so a
    # `setup` that killed one child before each of seven tests takes the whole
    # `AuroraMeter` tree down with it and the suite dies with
    # `** (EXIT from ...) shutdown`. Measured, by doing exactly that.
    :sys.replace_state(Cluster, &%{&1 | peers: %{}, last_message_ms: nil})

    attach()
    :ok
  end

  test "I05 cluster.lag reports peers seen and since_last_message_ms after remote batches" do
    tenant = unique_tenant("lag")
    period = Period.current(tenant).start

    AuroraMeter.Test.with_clock(~U[2026-09-16 02:00:00.000000Z], fn ->
      # Before anything arrives, "no peer has ever been heard from" is -1 and
      # not 0: zero on this measurement means a message arrived just now, which
      # is the opposite claim.
      first = sample()
      assert first.peers == 0
      assert first.since_last_message_ms == -1

      AuroraMeter.Test.simulate_node(:peer_a@nohost, [{tenant, :lagged, 5}], period)

      after_one = sample()
      assert after_one.peers == 1
      assert after_one.since_last_message_ms == 0

      AuroraMeter.Test.travel(3, :second)
      assert sample().since_last_message_ms == 3_000

      AuroraMeter.Test.simulate_node(:peer_b@nohost, [{tenant, :lagged, 2}], period)
      assert sample().peers == 2
    end)
  end

  test "I05 a peer not heard from for ten broadcast intervals leaves the peer map" do
    tenant = unique_tenant("lagprune")
    period = Period.current(tenant).start

    # The horizon is ten BROADCAST intervals, which is the cadence peers gossip
    # at, and not ten metrics intervals: a host running `metrics_interval: 0`
    # and its own scheduler still needs the map bounded.
    Config.with_config([{:aurora_meter, :broadcast_interval, 1_000}], fn ->
      AuroraMeter.Test.with_clock(~U[2026-09-16 03:00:00.000000Z], fn ->
        AuroraMeter.Test.simulate_node(:peer_c@nohost, [{tenant, :lagprune, 1}], period)
        assert sample().peers == 1

        # Nine intervals: still inside the horizon, so a peer is not forgotten
        # for being quiet for a while.
        AuroraMeter.Test.travel(9, :second)
        assert sample().peers == 1

        AuroraMeter.Test.travel(2, :second)
        assert sample().peers == 0
      end)
    end)
  end

  test "I05 a pruned peer is removed from the state and not merely from the report" do
    tenant = unique_tenant("lagleak")
    period = Period.current(tenant).start

    Config.with_config([{:aurora_meter, :broadcast_interval, 1_000}], fn ->
      AuroraMeter.Test.with_clock(~U[2026-09-16 04:00:00.000000Z], fn ->
        for n <- 1..5 do
          AuroraMeter.Test.simulate_node(
            :"peer_leak_#{n}@nohost",
            [{tenant, :lagleak, 1}],
            period
          )
        end

        assert sample().peers == 5

        AuroraMeter.Test.travel(11, :second)
        assert sample().peers == 0

        # The state itself, not the report. A map filtered for the report and
        # kept in full behind it reports the right number and grows for ever.
        assert :sys.get_state(Cluster).peers == %{}
      end)
    end)
  end

  test "I05 unreconciled_keys counts keys carrying peer value and falls to zero after a rebase" do
    tenant = unique_tenant("lagremote")
    period = Period.current(tenant).start
    key = {tenant, :lagremote, period}

    # The key must be warm for a remote delta to apply at all: a cold key seeds
    # from the database on first read, which already contains every flushed
    # delta.
    Config.with_config([{:aurora_meter, :history, false}], fn ->
      AuroraMeter.track(tenant, :lagremote, 1)
      {:ok, _} = Flusher.flush()

      before = sample().unreconciled_keys

      AuroraMeter.Test.simulate_node(:peer_d@nohost, [{tenant, :lagremote, 4}], period)
      assert Counter.remote_since_rebase(key) == 4
      assert sample().unreconciled_keys == before + 1

      # A flush rebases the key on the authoritative total, which clears the
      # remote column: that is what "reconciled" means here.
      AuroraMeter.track(tenant, :lagremote, 1)
      {:ok, _} = Flusher.flush()

      assert Counter.remote_since_rebase(key) == 0
      assert sample().unreconciled_keys == before
    end)
  end

  test "I05 unreconciled_keys is omitted above the scan ceiling, never reported as zero" do
    tenant = unique_tenant("lagceiling")
    period = Period.current(tenant).start

    # One region, not two nested ones: the configuration token is exclusive and
    # not reentrant, so a `with_config` inside a `with_config` queues behind
    # itself and the test times out rather than failing (measured: 30 s of
    # waiting, then 60 s of ExUnit timeout, with the holder reported as the
    # waiter itself).
    Config.with_config([{:aurora_meter, :history, false}], fn ->
      # Two warm keys, so the table is guaranteed to hold at least two rows and
      # `size - 1` below is a real ceiling rather than the `ceiling > 0` guard
      # in disguise.
      AuroraMeter.track(tenant, :lagceiling, 1)
      AuroraMeter.track(tenant, :lagceiling_b, 1)
      {:ok, _} = Flusher.flush()
      AuroraMeter.Test.simulate_node(:peer_e@nohost, [{tenant, :lagceiling, 3}], period)

      assert Map.has_key?(sample(), :unreconciled_keys)
    end)

    # The ceiling is set relative to the table's MEASURED size rather than to a
    # constant. The counters table is node-wide, so a constant of 1 is above the
    # size on a run where this module happens to go first and below it
    # otherwise: the assertion would then be about the seed.
    size = :ets.info(Store.counters_table(), :size)

    assert size >= 2,
           "the ceiling case needs at least two warm counters, or `size - 1` is zero and " <>
             "the test exercises the `ceiling > 0` guard instead of the comparison"

    # At the ceiling: included. The comparison is `<=`, and a test that only
    # ever exercised one side of it would pass for an implementation that
    # omitted the measurement always.
    Config.with_config(
      [{:aurora_meter, :history, false}, {:aurora_meter, :metrics_scan_ceiling, size}],
      fn -> assert Map.has_key?(sample(), :unreconciled_keys) end
    )

    Config.with_config(
      [{:aurora_meter, :history, false}, {:aurora_meter, :metrics_scan_ceiling, size - 1}],
      fn ->
        measurements = sample()

        refute Map.has_key?(measurements, :unreconciled_keys),
               "a zero here would tell an operator the cluster had converged, which is " <>
                 "exactly the case this gauge exists for"

        assert measurements.since_last_message_ms >= 0, "the rest of the gauge still reports"
      end
    )
  end

  test "I05 no lag event is emitted at all when cluster_sync is false" do
    Config.with_config([{:aurora_meter, :cluster_sync, false}], fn ->
      # `emit_lag/0` is the on-demand path a host with its own scheduler uses,
      # and it consults `enabled?/0` on every call rather than only at boot.
      assert :ok = Cluster.emit_lag()
      refute_receive {:lag, _measurements, _meta}, 300

      assert :ok = AuroraMeter.Telemetry.emit_gauges()
      refute_receive {:lag, _measurements, _meta}, 300
    end)

    # And with it back on, the same call does emit: a refutation that would
    # hold whatever the configuration said is not a test of the configuration.
    assert :ok = Cluster.emit_lag()
    assert_receive {:lag, _measurements, _meta}, 500
  end

  test "the lag gauge reports this node in metadata and never as a tag-eligible key" do
    measurements_and_meta = sample_with_meta()
    {_measurements, meta} = measurements_and_meta

    assert meta == %{node: node()}

    entry = Enum.find(AuroraMeter.Telemetry.events(), &(&1.event == @event))
    assert entry.tags == [], "a node name rotates for the life of a deployment"
  end

  defp attach do
    name = "cluster-lag-#{System.unique_integer([:positive])}"
    test = self()

    :telemetry.attach(
      name,
      @event,
      fn _event, measurements, meta, _config -> send(test, {:lag, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(name) end)
  end

  defp sample do
    {measurements, _meta} = sample_with_meta()
    measurements
  end

  defp sample_with_meta do
    :ok = Cluster.emit_lag()
    assert_receive {:lag, measurements, meta}, 500
    {measurements, meta}
  end
end
