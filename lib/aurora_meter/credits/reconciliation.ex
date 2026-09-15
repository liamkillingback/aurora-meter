defmodule AuroraMeter.Credits.Reconciliation do
  @moduledoc false
  # The run loop behind `AuroraMeter.Credits.reconcile_holds/1`. It lives here
  # rather than in `credits.ex` so the facade stays a facade.
  #
  # Three stages per hold, and the boundaries between them are the design:
  #
  #   1. List. One query, no transaction, no lock. What comes back is a
  #      snapshot: by the time the callback is asked about a hold, its own
  #      worker may already have closed it.
  #   2. Decide. The host's callback, in its own process under
  #      `AuroraMeter.TaskSupervisor`, outside any transaction and while no row
  #      lock is held. It can raise, hang or return nonsense; none of those can
  #      move money, because every one of them resolves to `:keep`.
  #   3. Apply. `Ledger.settle/3` or `Ledger.release/2`, each one transaction,
  #      each re-reading the hold's status under `FOR UPDATE` before writing.
  #      The decision is advisory until this point and may be refused here.
  #
  # ## What makes exactly one terminal transition happen (open finding X100)
  #
  # The hold row's own `FOR UPDATE` lock, and the `status = 'pending'` re-read
  # inside it. There is no lease, no fence and no duration anywhere in that
  # decision, which is the point: a reconciler decides whether work is abandoned,
  # and `clock_timestamp()` steps backwards by up to 439 ms on this hardware, so
  # anything that needed mutual exclusion at a sub-second scale could not get it
  # from a clock. It does not need to: Postgres already serialises two writers on
  # one row, and the loser reads what the winner wrote.
  #
  # The two durations that do survive are `:older_than`, which selects
  # candidates, and `age_seconds`, which is handed to the callback. Neither
  # decides anything. The cutoff is the caller's, at a scale of minutes to hours,
  # and having passed it makes a hold a *candidate*, never releasable; the age is
  # a number for a log line. `AuroraMeter.Credits.HoldReconciler` says so in the
  # words a host will read.
  #
  # `age_seconds` is measured with `Clock.now/0`, not `Clock.db_now/0`, and that
  # is deliberate. `AuroraMeter.Clock`'s rule is that both sides of a time
  # comparison come from the same clock, and which clock that is follows from
  # where the other side came from. The other side here is a hold row's
  # `inserted_at`, and that is stamped by **the node that took the hold, from a
  # node wall clock**: `Ecto.Schema`'s `timestamps/1` autogenerates it, because
  # `AuroraMeter.Schema.CreditTransaction`'s changeset does not cast
  # `inserted_at` (the `inserted_at: Clock.now()` in `Ledger.apply_entry/3` is
  # dropped, measured on 2026-09-15 and recorded in
  # `docs/evidence/v1/phase-05/05b-hold-recovery.md`). So it is a node clock on
  # that side, and `now/0` is the nearest thing to the same clock on this one.
  # `db_now/0` would put *two* clocks on the comparison and cost a round trip
  # for a number that decides nothing.
  #
  # Until the ledger is stamped by the database, which is 06a's along with L20's
  # move to `seq`, no reading makes a hold's age sound across two nodes. That is
  # the second reason `AuroraMeter.Credits.HoldReconciler` tells a host not to
  # decide from it, and the reason the age is clamped at zero rather than
  # trusted to be positive.

  require Logger

  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Credits.HoldReconciler
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeter.Tenant

  @supervisor AuroraMeter.TaskSupervisor
  @default_limit 200

  @typedoc """
  What one run examined and what it did.

  The shape is public and documented on `AuroraMeter.Credits`, which is where a
  host reads it; this module is `@moduledoc false`, so the type is defined there
  and named here rather than written twice.
  """
  @type report :: AuroraMeter.Credits.reconciliation_report()

  @typedoc "Why a hold ended the run in the state it did."
  @type outcome ::
          :no_reconciler
          | :kept
          | :callback_exit
          | :callback_timeout
          | :callback_invalid
          | :released
          | :settled
          | :already_closed
          | :failed
          | :settled_by_other
          | :released_by_other

  @empty %{examined: 0, kept: 0, released: 0, settled: 0, already_closed: 0, failed: 0}

  @doc false
  @spec run(keyword()) :: {:ok, report()} | {:error, term()}
  def run(opts) do
    # Before anything else, and with `fetch!`: a sweep with no cutoff is a sweep
    # over every open hold in the table, including the one taken a millisecond
    # ago, and the caller has to say so out loud.
    older_than = Keyword.fetch!(opts, :older_than)
    limit = Keyword.get(opts, :limit, @default_limit)
    ensure_supervisor!()

    listing = [
      older_than: older_than,
      limit: limit,
      tenant_key: tenant_key(opts),
      reference_prefix: Keyword.get(opts, :reference_prefix),
      after: Keyword.get(opts, :after)
    ]

    # One reading for the whole batch, so every hold in one run is measured
    # against the same instant and two holds a microsecond apart do not come
    # back with ages a second apart.
    now = Clock.now()
    reconciler = Keyword.get_lazy(opts, :reconciler, &Config.credits_hold_reconciler/0)
    timeout = Config.credits_hold_reconciler_timeout()

    case list(listing) do
      {:ok, rows} -> {:ok, examine(rows, reconciler, timeout, now, limit)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The listing is the one failure that stops a run: with no candidates there is
  # nothing to do, and a caller that cannot read the table wants to know rather
  # than to be told it examined nothing. Every *later* failure is per hold and
  # is counted, so one bad tenant cannot starve the tenants behind it.
  defp list(listing) do
    {:ok, Ledger.pending_holds(listing)}
  rescue
    exception -> {:error, exception}
  end

  defp examine(rows, reconciler, timeout, now, limit) do
    rows
    |> Enum.reduce(@empty, fn row, acc ->
      hold = to_hold(row, now)
      {decision, outcome, duration} = decide(reconciler, hold, timeout)
      outcome = apply_decision(decision, outcome, hold)
      emit(hold, decision, outcome, duration)
      count(acc, outcome)
    end)
    |> Map.put(:cursor, cursor(rows, limit))
  end

  @spec to_hold(CreditTransaction.t(), DateTime.t()) :: HoldReconciler.hold()
  defp to_hold(row, now) do
    %{
      tenant_key: row.tenant_key,
      reference: row.reference,
      amount: row.held_delta,
      held_at: row.inserted_at,
      # Clamped, because the two clocks involved are the reconciling node's and
      # the holding node's, and `non_neg_integer` is the type the behaviour
      # promises. A negative age is a clock disagreeing with itself, not a hold
      # taken in the future.
      age_seconds: max(0, DateTime.diff(now, row.inserted_at, :second)),
      metadata: row.metadata
    }
  end

  # -- deciding ---------------------------------------------------------------

  @spec decide(term(), HoldReconciler.hold(), pos_integer()) ::
          {HoldReconciler.decision(), outcome(), non_neg_integer()}
  defp decide(nil, _hold, _timeout), do: {:keep, :no_reconciler, 0}

  defp decide(reconciler, hold, timeout) do
    started = Clock.monotonic_ms()

    # `async_nolink`, not `async`. A callback that raises must not take the
    # reconciler down with it, and a callback that never returns must be
    # killable without the kill propagating back here.
    task = Task.Supervisor.async_nolink(@supervisor, fn -> invoke(reconciler, hold) end)

    result = Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)
    duration = Clock.monotonic_ms() - started

    {decision, outcome} = interpret(result, hold, timeout)
    {decision, outcome, duration}
  end

  defp invoke(module, hold) when is_atom(module), do: module.decide(hold)
  defp invoke({module, function}, hold), do: apply(module, function, [hold])
  defp invoke(fun, hold) when is_function(fun, 1), do: fun.(hold)

  # The outcome beside a `:release` or a `{:settle, _}` is what the run intends;
  # `apply_decision/3` confirms it or replaces it with what the ledger said.
  defp interpret({:ok, :keep}, _hold, _timeout), do: {:keep, :kept}
  defp interpret({:ok, :release}, _hold, _timeout), do: {:release, :released}

  defp interpret({:ok, {:settle, amount}}, _hold, _timeout)
       when is_integer(amount) and amount >= 0,
       do: {{:settle, amount}, :settled}

  defp interpret({:ok, other}, hold, _timeout) do
    warn(hold, :callback_invalid, "returned #{inspect(other)}")
    {:keep, :callback_invalid}
  end

  defp interpret({:exit, reason}, hold, _timeout) do
    warn(hold, :callback_exit, "exited: #{inspect(reason)}")
    {:keep, :callback_exit}
  end

  # `Task.yield/2` answers `nil` on a timeout and `Task.shutdown/2` answers
  # `nil` when the brutal kill got there first. Both are the same fact.
  defp interpret(nil, hold, timeout) do
    warn(hold, :callback_timeout, "did not answer within #{timeout}ms and was killed")
    {:keep, :callback_timeout}
  end

  defp warn(hold, outcome, detail) do
    Logger.warning(
      "AuroraMeter.Credits.reconcile_holds/1: the hold reconciler #{detail} for " <>
        "reference #{inspect(hold.reference)} (tenant #{inspect(hold.tenant_key)}). " <>
        "The hold is kept; outcome #{inspect(outcome)}."
    )
  end

  # -- applying ---------------------------------------------------------------

  @spec apply_decision(HoldReconciler.decision(), outcome(), HoldReconciler.hold()) :: outcome()
  defp apply_decision(:keep, outcome, _hold), do: outcome

  defp apply_decision(:release, _outcome, hold),
    do:
      attempt(hold, :released, fn ->
        Ledger.release(hold.reference, tenant_key: hold.tenant_key)
      end)

  defp apply_decision({:settle, amount}, _outcome, hold),
    do:
      attempt(hold, :settled, fn ->
        Ledger.settle(hold.reference, amount, tenant_key: hold.tenant_key)
      end)

  # One hold's application failing is not the run failing. A database that
  # cannot be reached for one tenant must not starve the tenants behind it, so
  # every way the ledger call can end badly, a returned error, a raise from the
  # driver, a pool checkout exit, is counted as `:failed` and the loop goes on.
  # The next run examines the hold again; nothing was written.
  defp attempt(hold, outcome, fun) do
    applied(fun.(), outcome, hold)
  catch
    kind, reason -> failed(hold, Exception.format(kind, reason, __STACKTRACE__))
  end

  defp applied({:ok, _txn}, outcome, _hold), do: outcome

  # The hold's own worker got there first, or another node's sweep did. That is
  # the system working, not a failure: the reconciler's decision was advisory
  # and it lost.
  defp applied({:error, reason}, _outcome, _hold) when reason in [:already_settled, :not_found],
    do: :already_closed

  defp applied({:error, reason}, _outcome, hold), do: failed(hold, inspect(reason))

  defp failed(hold, detail) do
    Logger.warning(
      "AuroraMeter.Credits.reconcile_holds/1: applying the decision for reference " <>
        "#{inspect(hold.reference)} (tenant #{inspect(hold.tenant_key)}) failed with " <>
        "#{detail}. The run continues; the hold is examined again next run."
    )

    :failed
  end

  # -- reporting --------------------------------------------------------------

  defp count(acc, outcome) do
    acc
    |> Map.update!(:examined, &(&1 + 1))
    |> Map.update!(bucket(outcome), &(&1 + 1))
  end

  defp bucket(:released), do: :released
  defp bucket(:settled), do: :settled
  defp bucket(:already_closed), do: :already_closed
  defp bucket(:failed), do: :failed
  # Everything else left the hold exactly as it found it.
  defp bucket(_kept), do: :kept

  # A cursor only when the page was full. A short page means the listing reached
  # the end of what matched, so there is nothing for a caller to resume from, and
  # handing one back would invite a second query that can only return nothing.
  defp cursor(rows, limit) when length(rows) == limit do
    last = List.last(rows)
    {last.inserted_at, last.id}
  end

  defp cursor(_rows, _limit), do: nil

  defp emit(hold, decision, outcome, duration) do
    :telemetry.execute(
      [:aurora_meter, :credits, :hold_reconciliation],
      %{amount: hold.amount, age_seconds: hold.age_seconds, duration: duration},
      %{
        tenant_key: hold.tenant_key,
        reference: hold.reference,
        decision: decision,
        outcome: outcome
      }
    )
  end

  @doc false
  # `with_credits/4` emits the same event when its hold turns out to have been
  # closed by somebody else, so one subscriber sees both halves of the race: the
  # reconciler's decision and what it did to the caller that was still running.
  @spec emit_external(CreditTransaction.t(), outcome(), DateTime.t()) :: :ok
  def emit_external(hold_row, outcome, now) do
    hold_row
    |> to_hold(now)
    |> emit(:none, outcome, 0)
  end

  # -- boot -------------------------------------------------------------------

  defp tenant_key(opts) do
    case Keyword.fetch(opts, :tenant) do
      {:ok, tenant} -> Tenant.to_key(tenant)
      :error -> nil
    end
  end

  defp ensure_supervisor! do
    if is_nil(Process.whereis(@supervisor)) do
      raise RuntimeError,
            "AuroraMeter.Credits.reconcile_holds/1 needs #{inspect(@supervisor)}, which is " <>
              "started by AuroraMeter's supervision tree. Add `AuroraMeter` to your " <>
              "application's children. The host callback runs in a task under that " <>
              "supervisor so that a callback which raises or hangs cannot take the caller " <>
              "with it."
    end

    :ok
  end
end
