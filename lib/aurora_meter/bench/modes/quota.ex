defmodule AuroraMeter.Bench.Modes.Quota do
  @moduledoc false

  # `reserve` and `with_quota`: the entitlement arithmetic, with
  # `AuroraMeter.Bench.MemoryStorage` in place of a database.
  #
  # `reserve` runs **two** passes per operation. The first is against a key with
  # the whole limit ahead of it, so every call is admitted; the second is
  # against a key warmed to `limit - per/2`, so exactly half of that worker's
  # calls cross the hard limit and take the denial branch (increment, compare,
  # roll back, answer `{:error, :limit_exceeded}`). A limit that is never
  # crossed is a branch that never runs, and a mode that measured only
  # admissions would be reporting half the function (`open-findings.md` X211).
  #
  # `limit_exceeded` counts towards `errors.by_tag` and `errors.rate` on
  # purpose: it is the expected outcome of those calls, the JSON says so in
  # `notes`, and hiding it would mean a real refusal was invisible in the same
  # field.

  @behaviour AuroraMeter.Bench.Mode

  import AuroraMeter.Bench.Mode, only: [compare: 3, merge: 1]

  alias AuroraMeter.Bench.MemoryStorage
  alias AuroraMeter.Bench.Modes
  alias AuroraMeter.Counter

  # The hard limit `AuroraMeter.Bench.Plans` declares for `:bench_limited`, read
  # from the plans module rather than repeated here.
  @limit AuroraMeter.Bench.Plans.reserve_limit()

  @impl AuroraMeter.Bench.Mode
  def prepare(%{mode: :reserve} = ctx) do
    MemoryStorage.put_plan(:bench_limited)
    ctx = Map.put(ctx, :period, resolve_period(ctx))
    headroom = div(ctx.per, 2)

    for worker <- 1..ctx.procs do
      Counter.warm(key(ctx, Modes.tenant(ctx, worker)))
      Counter.warm(key(ctx, denying(ctx, worker)), @limit - headroom)
    end

    ctx
    |> Map.put(:workload_extra, %{
      "keys" => ctx.procs * 2,
      "tenants" => ctx.procs * 2,
      "passes" => 2,
      "limit" => @limit,
      "headroom_per_worker" => headroom
    })
    |> add_note(
      "each operation is two AuroraMeter.reserve/3 calls: one against a key with the whole " <>
        "limit ahead of it and one against a key warmed to limit minus #{headroom}, so half " <>
        "of each worker's second pass crosses the hard limit. limit_exceeded is counted in " <>
        "errors.by_tag because it is the expected outcome of those calls, not a fault."
    )
  end

  def prepare(ctx) do
    MemoryStorage.put_plan(:bench_unlimited)
    ctx = Map.put(ctx, :period, resolve_period(ctx))

    for worker <- 1..ctx.procs, do: Counter.warm(key(ctx, Modes.tenant(ctx, worker)))

    ctx
    |> Map.put(:workload_extra, %{"keys" => ctx.procs, "tenants" => ctx.procs})
    |> add_note(
      "with_quota reserves, runs a no-op callback and commits the deferred reservation. The " <>
        "verification asserts that no reservation is left standing, which is what separates " <>
        "a commit from a leak."
    )
  end

  @impl AuroraMeter.Bench.Mode
  def operation(%{mode: :reserve} = ctx, worker, _index) do
    :ok = AuroraMeter.reserve(Modes.tenant(ctx, worker), Modes.feature(), 1)

    case AuroraMeter.reserve(denying(ctx, worker), Modes.feature(), 1) do
      :ok -> :ok
      {:error, tag} -> {:error, tag}
    end
  end

  def operation(ctx, worker, _index) do
    case AuroraMeter.with_quota(Modes.tenant(ctx, worker), Modes.feature(), fn -> :work end) do
      {:ok, :work} -> :ok
      {:error, tag} -> {:error, tag}
    end
  end

  @impl AuroraMeter.Bench.Mode
  def verify(%{mode: :reserve} = ctx, tally) do
    issued = tally.operations + tally.warmup_operations
    denied = Map.get(tally.errors.by_tag, "limit_exceeded", 0)

    merge([
      compare("admitted plus denied", admitted(ctx) + denied, issued * 2),
      compare("denied", denied, expected_denials(ctx, issued)),
      {denied > 0, ["the denial branch ran #{denied} times"]}
    ])
  end

  def verify(ctx, tally) do
    issued = tally.operations + tally.warmup_operations
    {committed, reserved} = settle(ctx)

    merge([
      compare("committed work", committed, issued),
      compare("reservations left standing", reserved, 0)
    ])
  end

  # Two readings of the same row, because either alone can be right for the
  # wrong reason: a denial that forgot to roll its increment back would still
  # balance the counts, and a pass that admitted everything would still sum.
  defp admitted(ctx) do
    headroom = div(ctx.per, 2)

    Enum.sum(
      for worker <- 1..ctx.procs do
        plain = Counter.value(Modes.tenant(ctx, worker), Modes.feature(), ctx.period)
        denying = Counter.value(denying(ctx, worker), Modes.feature(), ctx.period)
        plain + denying - (@limit - headroom)
      end
    )
  end

  # The warm-up runs the same two passes, so it eats the same headroom. That is
  # deliberate: with `warmup = per / 10` and `headroom = per / 2` the measured
  # phase still starts inside the headroom and crosses out of it, so both
  # branches run while the clock is running.
  defp expected_denials(ctx, issued) do
    per_worker = div(issued, ctx.procs)
    ctx.procs * max(per_worker - div(ctx.per, 2), 0)
  end

  # `reserved` has no public reader, and adding one for a benchmark would be a
  # worse trade than deriving it: `base/1` is `value - pending_flush - reserved`
  # and `take_pending/2` answers `pending_flush`, so the three known quantities
  # give the fourth. `take_pending/2` is destructive and this runs after the
  # measured phase, which is the only reason it is allowed here.
  defp settle(ctx) do
    Enum.reduce(1..ctx.procs, {0, 0}, fn worker, {values, reservations} ->
      key = key(ctx, Modes.tenant(ctx, worker))
      value = Counter.value(Modes.tenant(ctx, worker), Modes.feature(), ctx.period)
      base = Counter.base(key)
      pending = Counter.take_pending(key, :flush)
      {values + value, reservations + (value - pending - base)}
    end)
  end

  defp key(ctx, tenant), do: {tenant, Modes.feature(), ctx.period}

  defp denying(ctx, worker), do: Modes.tenant(ctx, worker) <> "_deny"

  # `AuroraMeter.reserve/3` resolves the tenant's period itself, so the
  # verification has to read the same one it wrote. Resolved once, from the
  # configured source, and recorded in the JSON.
  defp resolve_period(ctx), do: AuroraMeter.period(Modes.tenant(ctx, 1)).start

  defp add_note(ctx, note), do: Map.update(ctx, :notes, [note], &(&1 ++ [note]))
end
