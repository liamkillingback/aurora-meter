defmodule AuroraMeter.ClusterConvergenceTest do
  @moduledoc """
  I05: two and four simulated nodes, with gossip delayed and with gossip lost,
  and the hard-limit overshoot measured rather than reasoned about (build unit
  01c).

  The peers are simulated on one VM through `AuroraMeter.Cluster.apply/3`, the
  documented test hook, reached by `AuroraMeter.Test.simulate_node/3` and
  `simulate_flush/3`. That drives `Cluster.handle_batch/3`,
  `Counter.apply_remote/2` and `Counter.rebase/3` exactly as a received PubSub
  message does. Origins are literal foreign atoms, because `handle_batch/3`
  ignores a batch whose origin is `node()`.

  Delay and loss are scripted by withholding or never issuing a call, not by
  timing, and no `{:block_until, ref}` rendezvous is used: `Cluster.apply/3` is
  a synchronous `GenServer.call`, so message order here *is* call order and
  there is no race for a rendezvous to arbitrate. Manufacturing one would be
  theatre. For the same reason this module exercises no fault point and carries
  no `:fault` tag.

  What this does **not** prove: that `Phoenix.PubSub` itself delivers, that a
  netsplit heals, or that a real second BEAM converges. A multi-node harness is
  11d's; the limits of the simulation are stated in `docs/correctness.md` under
  I05 rather than left for a reader to discover.

  One thing here deliberately moves a view *downward*, and it is not a
  violation: a node's own flush re-bases unconditionally on the database total,
  so unflushed gossip from a peer leaves the view until that peer flushes and
  announces. Only a *totals announcement* is forbidden from lowering a view
  (`cluster.ex:106-121`), and that is what the assertions below check.
  """
  use AuroraMeter.DataCase, async: false

  alias AuroraMeter.Counter
  alias AuroraMeter.Flusher
  alias AuroraMeter.Period
  alias AuroraMeter.Storage
  alias AuroraMeter.Test, as: MeterTest

  @n2 :n2@test
  @n3 :n3@test
  @n4 :n4@test

  defp period(tenant), do: Period.current(tenant).start

  test "I05 two nodes with delayed gossip converge after a flush" do
    tenant = unique_tenant()
    p = period(tenant)

    AuroraMeter.track(tenant, :ops, 10)
    assert AuroraMeter.usage(tenant, :ops) == 10

    # n2's seven are gossiped while this node is flushing, and the message is
    # held rather than delivered. This node's own flush and announcement happen
    # first.
    assert {:ok, _} = Flusher.flush()
    assert Storage.load_counter(tenant, :ops, p) == 10
    assert AuroraMeter.usage(tenant, :ops) == 10

    # The held gossip arrives late.
    :ok = MeterTest.simulate_node(@n2, [{tenant, :ops, 7}])
    assert AuroraMeter.usage(tenant, :ops) == 17

    # And then n2 flushes its own seven and announces the resulting total.
    before = AuroraMeter.usage(tenant, :ops)
    total = peer_flush!(tenant, p, 7)
    assert total == 17
    :ok = MeterTest.simulate_flush(@n2, [{tenant, :ops, total}])
    assert AuroraMeter.usage(tenant, :ops) >= before

    assert Storage.load_counter(tenant, :ops, p) == 17
    assert AuroraMeter.usage(tenant, :ops) == 17
  end

  test "I05 two nodes with lost gossip converge after a flush" do
    tenant = unique_tenant()
    p = period(tenant)

    AuroraMeter.track(tenant, :ops, 10)
    assert {:ok, _} = Flusher.flush()

    # n2's delta gossip is dropped and never delivered: this node's view knows
    # nothing about the seven.
    assert AuroraMeter.usage(tenant, :ops) == 10

    total = peer_flush!(tenant, p, 7)
    :ok = MeterTest.simulate_flush(@n2, [{tenant, :ops, total}])

    # Convergence comes from the flush, not from the gossip. That is exactly the
    # documented guarantee: gossip narrows the window, the flush closes it.
    assert AuroraMeter.usage(tenant, :ops) == 17
    assert Storage.load_counter(tenant, :ops, p) == 17
  end

  test "I05 four nodes with mixed delayed and lost gossip converge after every node has flushed" do
    tenant = unique_tenant()
    p = period(tenant)
    key = {tenant, :ops, p}

    # 1. This node tracks eleven.
    AuroraMeter.track(tenant, :ops, 11)
    assert AuroraMeter.usage(tenant, :ops) == 11

    # 2. n2's gossip is delivered at once; n3's is delayed; n4's is lost.
    :ok = MeterTest.simulate_node(@n2, [{tenant, :ops, 3}])
    assert AuroraMeter.usage(tenant, :ops) == 14

    # 3. This node flushes. Its own flush re-bases on the database total, so
    #    n2's three leave the view until n2 flushes them: documented, and the
    #    one downward move in this script.
    assert {:ok, _} = Flusher.flush()
    assert Storage.load_counter(tenant, :ops, p) == 11
    assert AuroraMeter.usage(tenant, :ops) == 11

    # 4. n2 flushes its three and announces fourteen.
    assert announce!(tenant, key, @n2, peer_flush!(tenant, p, 3)) == 14

    # 5. n3's delayed gossip finally arrives.
    :ok = MeterTest.simulate_node(@n3, [{tenant, :ops, 5}])
    assert AuroraMeter.usage(tenant, :ops) == 19

    # 6. n3 flushes and announces nineteen.
    assert announce!(tenant, key, @n3, peer_flush!(tenant, p, 5)) == 19

    # 7. n4's gossip was lost outright; its flush is what tells this node.
    assert announce!(tenant, key, @n4, peer_flush!(tenant, p, 9)) == 28

    # 8. A stale re-announcement from n2 is ignored rather than obeyed (Z3).
    assert announce!(tenant, key, @n2, 14) == 28

    assert Storage.load_counter(tenant, :ops, p) == 11 + 3 + 5 + 9
    assert AuroraMeter.usage(tenant, :ops) == 28
  end

  test "I05 overshoot is bounded by what other nodes admitted between announcements" do
    tenant = unique_tenant()
    p = period(tenant)
    limit = 50
    assert AuroraMeter.remaining(tenant, :ai_generations) == limit

    # n2 admits twenty against its own view of the same counter. Its gossip is
    # still in flight, so this node's view does not include them.
    admitted_by_peer = 20

    admitted_here =
      Enum.count(1..60, fn _ -> AuroraMeter.reserve(tenant, :ai_generations) == :ok end)

    # On its own view this node is exactly at the cap, which is all I04 claims.
    assert admitted_here == limit
    assert AuroraMeter.reserve(tenant, :ai_generations) == {:error, :limit_exceeded}

    # The peer's admissions land.
    :ok = MeterTest.simulate_node(@n2, [{tenant, :ai_generations, admitted_by_peer}])
    assert AuroraMeter.usage(tenant, :ai_generations) == limit + admitted_by_peer

    overshoot = admitted_here + admitted_by_peer - limit
    assert overshoot == 20

    # The bound: the cluster can exceed the cap only by what the other nodes
    # admitted since the last announcement this node applied. It is not zero and
    # Aurora Meter does not claim a strict global quota.
    assert overshoot <= admitted_by_peer

    # And it is durable rather than a reporting artefact: both nodes flush and
    # the database holds seventy against a limit of fifty.
    assert {:ok, _} = Flusher.flush()
    total = peer_flush!(tenant, p, admitted_by_peer, :ai_generations)
    :ok = MeterTest.simulate_flush(@n2, [{tenant, :ai_generations, total}])

    assert Storage.load_counter(tenant, :ai_generations, p) == 70
    assert AuroraMeter.usage(tenant, :ai_generations) == 70
  end

  # -- helpers ----------------------------------------------------------------

  # A peer node writing its own delta straight into the database, which is what
  # its flush does, and returning the total the database now holds.
  defp peer_flush!(tenant, p, delta, feature \\ :ops) do
    {:ok, [%{value: total}]} =
      Storage.add_counters([
        %{tenant_key: tenant, feature: feature, period_start: p, delta: delta}
      ])

    total
  end

  # A totals announcement, with the invariant checked around it: an announcement
  # may raise this node's view and may be ignored, but may never lower it.
  defp announce!(tenant, key, origin, total) do
    before = Counter.value(tenant, :ops, elem(key, 2))
    :ok = MeterTest.simulate_flush(origin, [{tenant, :ops, total}])
    after_value = Counter.value(tenant, :ops, elem(key, 2))

    assert after_value >= before,
           "a totals announcement of #{total} from #{origin} moved the view " <>
             "from #{before} to #{after_value}"

    after_value
  end
end
