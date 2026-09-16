defmodule AuroraMeter.Bench.Modes.Wallet do
  @moduledoc false

  # `credits_debit` and `credits_hot_wallet`: the prepaid ledger, end to end.
  #
  # Both run with lots **enabled**, which is the V1 allocator and not the legacy
  # wallet arithmetic. That matters for the figure: `open-findings.md` X248
  # measured the allocator's per-write cost growing with the wallet's lot count,
  # because it reads and locks the whole book and runs one aggregate
  # conservation check per write. Those numbers were taken with Ecto's debug
  # logging on, so only their shape was load bearing; this is the first
  # measurement on a harness built for it, and `workload.lots` records how many
  # lots each wallet held so the figure is attached to the wallet shape that
  # produced it.
  #
  # `credits_hot_wallet` is the same debit against one wallet from every worker.
  # The ledger serialises on one balance row lock, so the figure is contention
  # and the record says so in `notes`; it is not an aggregate throughput and
  # must never be quoted as one.

  @behaviour AuroraMeter.Bench.Mode

  import AuroraMeter.Bench.Mode, only: [compare: 3, merge: 1]

  alias AuroraMeter.Bench.Modes
  alias AuroraMeter.Credits
  alias AuroraMeter.Credits.Ledger

  @dollar 1_000_000
  @grant 1_000 * @dollar

  @impl AuroraMeter.Bench.Mode
  def prepare(%{mode: :credits_hot_wallet} = ctx) do
    fund([Modes.shared_tenant(ctx)])

    ctx
    |> Map.put(:workload_extra, %{
      "tenants" => 1,
      "wallets" => 1,
      "lots" => 1,
      "contended" => true,
      "grant_micro_dollars" => @grant
    })
    |> add_note(contention_note())
    |> add_note(allocator_note())
  end

  def prepare(ctx) do
    fund(Enum.map(1..ctx.procs, &Modes.tenant(ctx, &1)))

    ctx
    |> Map.put(:workload_extra, %{
      "tenants" => ctx.procs,
      "wallets" => ctx.procs,
      "lots" => 1,
      "grant_micro_dollars" => @grant
    })
    |> add_note(allocator_note())
  end

  @impl AuroraMeter.Bench.Mode
  def operation(%{mode: :credits_hot_wallet} = ctx, worker, index),
    do: debit(Modes.shared_tenant(ctx), "#{ctx.short_id}-#{worker}-#{index}")

  def operation(ctx, worker, index),
    do: debit(Modes.tenant(ctx, worker), "#{ctx.short_id}-#{worker}-#{index}")

  @impl AuroraMeter.Bench.Mode
  def verify(%{mode: :credits_hot_wallet} = ctx, tally) do
    spent = tally.operations + tally.warmup_operations
    balance = Credits.balance(Modes.shared_tenant(ctx))

    merge([
      compare("balance", balance.balance, @grant - spent),
      compare("held", balance.held, 0),
      compare("debt", balance.debt, 0)
    ])
  end

  def verify(ctx, tally) do
    spent = tally.operations + tally.warmup_operations
    balances = Enum.map(1..ctx.procs, &Credits.balance(Modes.tenant(ctx, &1)))
    total = Enum.sum(Enum.map(balances, & &1.balance))

    merge([
      compare("balance across wallets", total, ctx.procs * @grant - spent),
      {Enum.all?(balances, &(&1.balance >= 0)), ["no wallet negative"]},
      {Enum.all?(balances, &(&1.held == 0)), ["nothing held"]}
    ])
  end

  # One grant per wallet, so every measured debit runs against a one-lot book.
  # A bench that funded a thousand lots would be measuring a different
  # deployment without saying so; the count is in the record either way.
  defp fund(tenants) do
    for tenant <- tenants do
      Ledger.enable_lots!(tenant)
      {:ok, _txn} = Credits.grant(tenant, @grant, reference: "#{tenant}:fund")
    end

    :ok
  end

  # `Credits.debit/4` answers `{:error, :duplicate_reference}` or
  # `{:error, :insufficient_credits}` and nothing else, so there is no tagged
  # tuple clause here: dialyzer refuses a pattern that can never match, and a
  # defensive clause for a shape the function cannot return is a comment
  # pretending to be code.
  defp debit(tenant, reference) do
    case Credits.debit(tenant, 1, reference) do
      {:ok, _txn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp allocator_note do
    "the wallet has lots enabled (AuroraMeter.Credits.Ledger.enable_lots!/1), so this is the " <>
      "V1 allocator and not the legacy wallet arithmetic. workload.lots is how many lots each " <>
      "wallet held during the measured phase, because the allocator reads and locks the whole " <>
      "book per write and its cost is bounded by that count (open-findings.md X248)."
  end

  defp contention_note do
    "every worker debits one shared wallet, which the ledger serialises on one balance row " <>
      "lock. This figure is contention, not aggregate ledger throughput."
  end

  defp add_note(ctx, note), do: Map.update(ctx, :notes, [note], &(&1 ++ [note]))
end
