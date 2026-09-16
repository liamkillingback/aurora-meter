defmodule AuroraMeter.Bench.PlansTest do
  @moduledoc """
  The bench plans, and the one thing about them that can silently rot.

  `AuroraMeter.Plans`'s DSL is compile time, so the hard limits are literals in
  the plan blocks, and the modes assert against readers beside them. Two numbers
  that must agree and are written twice will eventually disagree, and the way it
  would show is a mode asserting an overshoot against a limit the plan no longer
  declares, which reads as a correct run.
  """
  use ExUnit.Case, async: true

  alias AuroraMeter.Bench.Modes
  alias AuroraMeter.Bench.Plans
  # `AuroraMeter.Plans.get/1` reads the CONFIGURED plans module, which in this
  # suite is `AuroraMeter.TestPlans`. The bench plans are only the configured
  # ones while a bench run is in progress, so the lookup is pointed at them
  # explicitly here rather than by mutating global configuration in an async
  # suite.
  defp plan(plan_id), do: Map.get(Plans.__aurora_plans__(), {plan_id, "1"})

  test "the reserve limit the plan declares is the one the reader answers" do
    assert limit_of(:bench_limited) == Plans.reserve_limit()
  end

  test "the cluster limit the plan declares is the one the reader answers" do
    assert limit_of(:bench_cluster) == Plans.cluster_limit()
  end

  test "the cluster limit is small enough that the default workload crosses it" do
    # Two nodes at the default 20,000 reservations each is 40,000 against a
    # 10,000 limit, so the overshoot branch runs. A limit above the workload
    # would make `cluster_2` report an overshoot of zero for ever, which reads
    # exactly like a cluster that never overshoots (open-findings.md X211).
    assert Plans.cluster_limit() < 2 * 20_000
  end

  test "every bench plan declares the feature every mode meters" do
    for plan_id <- [:bench_unlimited, :bench_limited, :bench_cluster] do
      plan = plan(plan_id)
      assert plan, "#{plan_id} is not declared"

      assert Map.has_key?(plan.features, Modes.feature()),
             "#{plan_id} does not declare #{inspect(Modes.feature())}, so " <>
               "every mode using it would be measuring the undeclared-feature policy instead"
    end
  end

  defp limit_of(plan_id) do
    {:limit, limit, :hard} = Map.fetch!(plan(plan_id).features, Modes.feature())
    limit
  end
end
