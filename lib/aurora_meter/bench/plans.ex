defmodule AuroraMeter.Bench.Plans do
  @moduledoc false

  # The plans `mix aurora_meter.bench` measures against.
  #
  # It is in `lib/` rather than in `test/support` because the task ships: a host
  # sizing its own deployment runs `mix aurora_meter.bench` against its own
  # database, and a bench that could only run inside this repository's test
  # environment would not be the trust artifact it is meant to be.
  #
  # Three plans, each existing for one group of modes:
  #
  #   * `:bench_unlimited` declares `:ops` as a plain counter, so `reserve`'s
  #     admitting pass and every durable and ledger mode measure the operation
  #     and not a denial;
  #   * `:bench_limited` puts a hard limit far above any workload on `:ops`, so
  #     the denying `reserve` pass has a real limit to cross after the key is
  #     warmed close to it;
  #   * `:bench_cluster` carries the small hard limit the cluster modes
  #     deliberately overshoot.
  #
  # Both limits are literals because the DSL is compile time. Each has a reader
  # beside it, and `AuroraMeter.Bench.PlansTest` asserts that the reader and the
  # compiled plan agree, so a mode cannot end up asserting against a limit the
  # plan no longer declares.

  use AuroraMeter.Plans

  plan :bench_unlimited do
    price 0
    counter :ops
    feature :api_access, true
  end

  plan :bench_limited do
    price 0
    limit :ops, 1_000_000_000, :hard
    feature :api_access, true
  end

  plan :bench_cluster do
    price 0
    limit :ops, 10_000, :hard
    feature :api_access, true
  end

  @doc "The hard limit `:bench_limited` declares, which the denying `reserve` pass crosses."
  @spec reserve_limit() :: pos_integer()
  def reserve_limit, do: 1_000_000_000

  @doc "The hard limit `:bench_cluster` declares, which the cluster modes overshoot."
  @spec cluster_limit() :: pos_integer()
  def cluster_limit, do: 10_000
end
