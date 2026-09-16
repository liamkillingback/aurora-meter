defmodule AuroraMeter.Credits.Recurrences do
  @moduledoc """
  Recurring credit allowances: one grant per tenant, entitlement, plan version
  and billing period, with a capped rollover and a bounded catch-up after
  downtime.

  A plan declares the policy with `AuroraMeter.Plans.recurring_credits/2`; a
  plan that declares none grants nothing, which is what "recurring grants
  default to disabled" means. `run/1` is the operation: call it from Oban
  (`AuroraMeter.Oban.RecurringGrants`), from Quantum, from a Kubernetes CronJob
  or from `iex`. It is not a process and holds no state between runs.

      AuroraMeter.Credits.Recurrences.run(limit: 5_000)

  ## What a run does

  It walks entitled subscriptions in keyset order, resolves each tenant's plan,
  skips it immediately when the plan declares no allowance, and works out which
  periods each allowance still owes. Each period is its own transaction under
  the wallet's balance row lock, so a twelve-period catch-up is twelve short
  transactions and a concurrent debit interleaves between them.

  Size the run so it can visit every entitled tenant at least once per period:
  `limit: 5_000` on an hourly schedule visits 120,000 tenants a day.

  ## Once per period, whatever the scheduler does

  The guarantee is not that the job runs once. Two guards, both evaluated inside
  the balance row lock, make a second run a no-op:

    * `aurora_meter_credit_recurrences` is `UNIQUE (tenant_key, key)`, and the
      period's row is inserted with `ON CONFLICT DO NOTHING`. Zero rows back
      means another node has this period.
    * the grant carries the period's reference, and
      `aurora_meter_credit_transactions` is `UNIQUE (kind, reference)`.

  The two are deliberately redundant because this is money. Neither is a lease
  and neither is a duration, so neither can be inverted by a clock that steps
  backwards (`AuroraMeter.Clock`).

  ## Two clocks

  Choosing a period is a wall-clock question ("what period is it now"), so the
  walk takes `AuroraMeter.Clock.now/0`. Every decision inside a transaction
  compares against a column this database stamped, so those take
  `AuroraMeter.Clock.db_now/0`. Ordering never takes a clock at all: periods are
  ordered by `period_start`, which is a boundary the period source computed, not
  a reading of any clock.

  ## Rollover

  `rollover: n` carries at most `n` micro-dollars of one period's **unused**
  allowance into the next, as a new lot with its own reference and its own
  allocation trail. Unused means what that period's lots did not spend, whether
  or not the expiry sweep has already destroyed it: `available + expired` is the
  same number either way, which is what makes the carry independent of whether
  the sweep or this engine reached the lot first.

  It does not accumulate. Two idle periods with a cap of 1,000,000 leave the
  third holding its own allowance plus 1,000,000, never 2,000,000, because the
  cap applies to the whole of the previous period rather than to each of its
  lots.

  The cap comes from the **previous period's stored policy**, never from the
  compiled plan. Raising a plan's cap does not retroactively raise what an
  already-issued period may carry out of itself.

  ## Catch-up, and why a missed period is not fresh money

  A tenant whose job has not run for three periods gets those three periods in
  chronological order, each granted and expired in the same transaction and
  recorded `issued_and_expired`, then its live period. The history is complete
  and nothing that was owed months ago arrives spendable today.

  A tenant seen for the first time gets its current period only. Aurora Meter
  does not invent history it never recorded, so there is no back-pay for periods
  before a tenant's first recurrence row, and adopting an allowance mid-period
  grants the whole of that period rather than a pro-rated part of it.

  ## Requirements and limits

    * The wallet must be on the lot engine (`lots_enabled_at` set). A wallet the
      allocator does not own is skipped with `reason: :lots_disabled`: the
      allowance, the cap and the catch-up are all defined over lots, and a
      second, weaker implementation over the legacy projection is not one this
      package will carry. See `docs/upgrading-to-lots.md`.

      A tenant with **no wallet at all** is not skipped: since 0.5.0 the grant
      that pays the allowance is what creates the wallet, and a wallet created
      now is born on the allocator. This is the ordinary case for a customer
      who has just subscribed, and an allowance is usually the first credit a
      wallet ever sees.
    * The storage adapter must implement
      `c:AuroraMeter.Storage.list_subscriptions/2`. A run that cannot list
      subscriptions returns `{:error, {:unsupported, :list_subscriptions}}`;
      drive it with explicit `:tenant` values instead.

  ## Pausing

      AuroraMeter.Operations.pause("credits_recurrences:global")

  A paused run returns `{:ok, %{paused: true}}` and writes nothing. The pause is
  read before every batch, so it takes effect within one batch rather than one
  run.
  """

  require Logger

  import Ecto.Query, only: [from: 2]

  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Credits.Ledger
  alias AuroraMeter.Operations
  alias AuroraMeter.Period
  alias AuroraMeter.Plan
  alias AuroraMeter.Plans
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Schema.CreditRecurrence
  alias AuroraMeter.Schema.Subscription
  alias AuroraMeter.Storage
  alias AuroraMeter.Tenant

  @operation "credits_recurrences:global"

  @namespace "recurring:"

  # The documented default, and now the **fallback** rather than the only
  # answer. Build unit 07c resolves each period's version from
  # `AuroraMeter.Plans.effective_for/2`, so a period is granted under the
  # contract that period was sold under rather than under whatever the tenant
  # is on today (task 07.08). Two things keep that compatible with the keys
  # build unit 06d already wrote:
  #
  #   * a tenant on version "1" resolves to "1", so the key shape is byte for
  #     byte what 06d wrote and no period is granted a second time, and
  #   * "already granted" is decided by the period, not by the key.
  #     `last_recurrence/2` finds the newest row for the entitlement by
  #     `period_start` and `periods/4` then returns nothing for a period already
  #     recorded, whatever version segment its key carries. The `UNIQUE
  #     (tenant_key, key)` index is the racing-schedulers guard underneath that,
  #     not the primary one.
  #
  # An unresolvable period falls back to the subscription's own version, and
  # only then to this literal. Neither invents a version: they name the one the
  # row already claims.
  @default_version "1"

  @schema NimbleOptions.new!(
            limit: [
              type: :pos_integer,
              default: 500,
              doc: "The most tenants one run visits."
            ],
            batch: [
              type: :pos_integer,
              default: 50,
              doc: "Tenants per batch, and therefore per checkpoint write."
            ],
            max_periods: [
              type: :pos_integer,
              default: 12,
              doc: "The most catch-up periods one run processes for one entitlement."
            ],
            tenant: [
              type: :any,
              default: nil,
              doc: "One tenant or a list of them, processed without the subscription scan."
            ],
            now: [
              type: :any,
              default: nil,
              doc: "The instant periods are resolved against. Defaults to `Clock.now/0`."
            ],
            dry_run: [
              type: :boolean,
              default: false,
              doc: "Report what would be granted and write nothing."
            ]
          )

  # Every counter is a number under a string key, because `Operations.run_batches/3`
  # merges two batches' counts by adding numbers and replacing anything else. A
  # list of tenants accumulated here would silently become the last batch's list.
  # A reason is therefore its own counter (`"skipped:not_entitled"`), and the
  # tenant a count belongs to is in the telemetry event and in the recurrence
  # rows, which is where a name belongs anyway.
  # `duplicate` is "this period was already granted, by this run or another".
  # `conflict` is the half of it that the unique index refused **inside the
  # balance row lock**, which is the branch two schedulers racing take and the
  # one an ordinary run never does. They are counted separately because a test
  # that could not tell them apart would report a race it never had (X214).
  @counters ~w(examined tenants granted duplicate conflict issued_and_expired skipped failed
               catching_up amount rollover)

  @empty Map.new(@counters, &{&1, 0})

  @typedoc "What one run did. The map may gain keys in a later release."
  @type summary :: %{
          paused: boolean(),
          counts: %{optional(String.t()) => non_neg_integer()},
          reasons: %{optional(String.t()) => non_neg_integer()},
          cursor: map() | nil,
          stopped: :complete | :paused | :max_batches,
          dry_run: boolean()
        }

  @typedoc "What the operator sees between runs."
  @type status :: %{
          name: String.t(),
          paused: boolean(),
          cursor: map() | nil,
          counts: map(),
          state: String.t() | nil,
          recurrences: [CreditRecurrence.t()]
        }

  @doc """
  The reserved reference namespace, `"recurring:"`.

  `AuroraMeter.Credits.grant/3`, `hold/4`, `debit/4` and `reverse/4` raise
  `ArgumentError` for a caller-supplied reference beginning with it, because
  this engine mints its own references there and a collision would make a host's
  manual grant look like a period that had already been issued. Nothing else is
  reserved: manual grants keep using any string.

  ## Examples

      iex> AuroraMeter.Credits.Recurrences.namespace()
      "recurring:"

  """
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc """
  The operation name this engine pauses, resumes and checkpoints under.

  ## Examples

      iex> AuroraMeter.Credits.Recurrences.operation()
      "credits_recurrences:global"

  """
  @spec operation() :: String.t()
  def operation, do: @operation

  @doc """
  Issues every recurring allowance that has come due.

  #{NimbleOptions.docs(@schema)}

  Returns `{:ok, summary}`. A tenant that cannot be processed is counted and
  stepped over: one wallet's fault must not starve the wallets behind it, and
  the direction it fails in is the safe one, a grant not yet made. Only a
  failure of the scan itself ends the run with `{:error, reason}`.

  Emits `[:aurora_meter, :credits, :recurrence]` per period examined, with
  measurements `%{amount, rollover_amount}` and metadata `%{tenant_key, name,
  plan_id, plan_version, period_start, result, reason}`.

  ## Examples

      {:ok, summary} = AuroraMeter.Credits.Recurrences.run(tenant: "org_1")
      summary.counts["granted"]
      #=> 1

  """
  @spec run(keyword()) :: {:ok, summary()} | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    opts = NimbleOptions.validate!(opts, @schema)
    context = context(opts)

    case opts[:tenant] do
      nil -> run_scan(context, opts)
      tenant -> run_tenants(context, List.wrap(tenant))
    end
  end

  @doc """
  What the engine has done, and whether an operator has stopped it.

  Options: `:tenant` (also return that tenant's recurrence rows, newest period
  first) and `:limit` (default 50) on those rows.

  ## Examples

      AuroraMeter.Credits.Recurrences.status(tenant: "org_1")

  """
  @spec status(keyword()) :: status()
  def status(opts \\ []) when is_list(opts) do
    checkpoint = Operations.checkpoint(@operation)

    %{
      name: @operation,
      paused: Operations.paused?(@operation),
      cursor: checkpoint && checkpoint.cursor,
      counts: (checkpoint && checkpoint.counts) || %{},
      state: checkpoint && checkpoint.state,
      recurrences: recurrences_of(opts[:tenant], Keyword.get(opts, :limit, 50))
    }
  end

  @doc """
  The periods one entitlement still owes, oldest first.

  `last_start` is the newest period already recorded, or `nil` for a tenant with
  no recurrence row, which gets its current period and no back-pay. The walk is
  expressed entirely in terms the period source can answer
  (`AuroraMeter.Period.containing/2` of the previous period's exclusive end), so
  a weekly, a subscription-aligned or any other custom source walks correctly
  with no arithmetic on month boundaries anywhere.

  Returns `{:ok, periods, :complete | :truncated | :up_to_date}`, or
  `{:error, reason}` for a source that raises or that does not move forward.
  `:truncated` means `max_periods` was reached with the live period still ahead;
  the next run continues from where this one stopped. `:up_to_date` means the
  live period is already recorded, which is what the second and every later run
  inside one period sees: the engine recognises the period from its own row and
  opens no transaction at all.

  ## Examples

      iex> {:ok, periods, :complete} =
      ...>   AuroraMeter.Credits.Recurrences.periods("org_1", nil, ~U[2026-09-16 10:00:00Z], 12)
      iex> Enum.map(periods, & &1.start)
      [~U[2026-09-01 00:00:00Z]]

      iex> {:ok, periods, :complete} =
      ...>   AuroraMeter.Credits.Recurrences.periods(
      ...>     "org_1", ~U[2026-07-01 00:00:00Z], ~U[2026-09-16 10:00:00Z], 12)
      iex> Enum.map(periods, & &1.start)
      [~U[2026-08-01 00:00:00Z], ~U[2026-09-01 00:00:00Z]]

  """
  @spec periods(term(), DateTime.t() | nil, DateTime.t(), pos_integer()) ::
          {:ok, [Period.t()], :complete | :truncated | :up_to_date} | {:error, term()}
  def periods(tenant, last_start, now, max_periods) do
    current = Period.current!(tenant, now)

    cond do
      is_nil(last_start) -> {:ok, [current], :complete}
      DateTime.compare(last_start, current.start) != :lt -> {:ok, [], :up_to_date}
      true -> collect(tenant, Period.containing(tenant, last_start), current, max_periods, [])
    end
  rescue
    exception -> {:error, {:period_source_error, exception}}
  end

  # -- the run ----------------------------------------------------------------

  defp context(opts) do
    %{
      now: opts[:now] || Clock.now(),
      max_periods: opts[:max_periods],
      dry_run: opts[:dry_run],
      version: @default_version
    }
  end

  defp run_scan(context, opts) do
    max_batches = ceil(opts[:limit] / opts[:batch])

    @operation
    |> Operations.run_batches([max_batches: max_batches, counts: @empty], fn cursor ->
      scan_batch(context, cursor, opts[:batch])
    end)
    |> report(context)
  end

  defp run_tenants(context, tenants) do
    if Operations.paused?(@operation) do
      report({:paused, blank_report(:paused)}, context)
    else
      counts =
        Enum.reduce(tenants, @empty, fn tenant, acc ->
          merge(acc, tenant_counts(Tenant.to_key(tenant), context))
        end)

      report({:ok, %{blank_report(:complete) | counts: counts, batches: 1}}, context)
    end
  end

  defp blank_report(stopped),
    do: %{batches: 0, counts: @empty, cursor: nil, stopped: stopped}

  defp scan_batch(context, cursor, batch) do
    case list_subscriptions(cursor, batch) do
      {:ok, rows, next} ->
        counts =
          Enum.reduce(rows, %{}, fn row, acc ->
            merge(acc, tenant_counts(row.tenant_key, context))
          end)

        {:ok, %{cursor: next && %{"tenant_key" => next}, counts: counts}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_subscriptions(cursor, batch) do
    {rows, next} =
      Storage.list_subscriptions(cursor && cursor["tenant_key"],
        limit: batch,
        status_in: Subscription.entitled_statuses()
      )

    {:ok, rows, next}
  rescue
    UndefinedFunctionError -> {:error, {:unsupported, :list_subscriptions}}
  end

  defp report({:ok, batch_report}, context), do: {:ok, summary(batch_report, false, context)}
  defp report({:paused, batch_report}, context), do: {:ok, summary(batch_report, true, context)}
  defp report({:error, reason}, _context), do: {:error, reason}

  defp summary(batch_report, paused?, context) do
    counts = batch_report.counts

    %{
      paused: paused?,
      counts: Map.take(counts, @counters),
      reasons:
        for {"skipped:" <> reason, n} <- counts, into: %{} do
          {reason, n}
        end,
      cursor: batch_report.cursor,
      stopped: batch_report.stopped,
      dry_run: context.dry_run
    }
  end

  # -- one tenant -------------------------------------------------------------

  defp tenant_counts(tenant_key, context) do
    counts = count(%{}, "examined")

    case resolve(tenant_key) do
      {:ok, plan, subscription} ->
        Enum.reduce(plan.recurring_credits, count(counts, "tenants"), fn credit, acc ->
          merge(acc, entitlement_counts(subscription, plan, credit, context))
        end)

      {:skip, reason} ->
        skip(counts, reason)
    end
  end

  defp resolve(tenant_key) do
    case Storage.get_subscription(tenant_key) do
      nil -> {:skip, :no_subscription}
      subscription -> resolve_plan(subscription)
    end
  end

  defp resolve_plan(subscription) do
    if Subscription.entitled?(subscription),
      do: plan_of(subscription),
      else: {:skip, :not_entitled}
  end

  # **The tenant's own version, not the one effective today** (build unit 07c,
  # G07 bullet 1). `Plans.get/1` answers the version in force **now**, so with
  # it a tenant still on version 1 received version 2's allowance the moment
  # version 2's `effective_at` passed, which is the repricing decision D05 and
  # invariant I17 forbid, in the one place the gate names explicitly ("their
  # recurring grant amount unchanged"). `Plans.get/2` resolves compiled code
  # first and the stored snapshot second, so a tenant on a version whose block
  # has been deleted keeps its allowance rather than losing it.
  #
  # A row with no `plan_version` is the window between core schema version 10
  # and the first `register!/0`; it falls back to `get/1` so an installation in
  # that window keeps granting rather than stopping.
  defp plan_of(subscription) do
    case assigned_plan(subscription) do
      nil -> {:skip, :unknown_plan}
      %{recurring_credits: []} -> {:skip, :no_recurring_credits}
      plan -> lots_gate(plan, subscription)
    end
  end

  defp assigned_plan(%Subscription{plan_id: plan_id, plan_version: version}) do
    case plan_atom(plan_id) do
      nil -> nil
      id when is_binary(version) -> Plans.get(id, version) || Plans.get(id)
      id -> Plans.get(id)
    end
  end

  # Checked here as well as under the balance lock, so a wallet the allocator
  # does not own costs one read rather than one transaction per period. The
  # reading that decides is still the locked one in `AuroraMeter.Credits.Ledger`.
  defp lots_gate(plan, subscription) do
    if lots?(subscription.tenant_key) do
      {:ok, plan, subscription}
    else
      {:skip, :lots_disabled}
    end
  end

  defp plan_atom(nil), do: nil

  defp plan_atom(plan_id) do
    String.to_existing_atom(plan_id)
  rescue
    ArgumentError -> nil
  end

  # -- one entitlement --------------------------------------------------------

  defp entitlement_counts(subscription, plan, credit, context) do
    tenant_key = subscription.tenant_key
    # The version the telemetry event reports is the tenant's **current**
    # assignment, which is what an operator watching a run wants to see. Each
    # period's own version is resolved separately, in `request/6`.
    context = %{context | version: subscription.plan_version || @default_version}
    last = last_recurrence(tenant_key, credit.name)
    last_start = last && last.period_start

    case periods(tenant_key, last_start, context.now, context.max_periods) do
      # The live period is already recorded. Recognised from the row rather than
      # by opening a transaction and letting the conflict guard refuse it: an
      # hourly sweep visits every tenant many times inside one period, and the
      # guard is there for two schedulers racing, not for the ordinary case.
      {:ok, [], :up_to_date} ->
        emit(event(tenant_key, plan, credit, context), nil, {:duplicate, :up_to_date}, {0, 0})
        count(%{}, "duplicate")

      {:ok, periods, stopped} ->
        subscription
        |> apply_periods(plan, credit, periods, last, context)
        |> note_catching_up(stopped)

      {:error, reason} ->
        warn_source(tenant_key, credit.name, reason)

        emit(
          event(tenant_key, plan, credit, context),
          nil,
          {:skipped, reason_tag(reason)},
          {0, 0}
        )

        skip(%{}, reason_tag(reason))
    end
  end

  # The metadata every event for one tenant and one entitlement shares, built
  # once so the emitter takes four arguments rather than nine.
  defp event(tenant_key, plan, credit, context) do
    %{
      tenant_key: tenant_key,
      name: credit.name,
      plan_id: plan.id,
      plan_version: context.version
    }
  end

  defp apply_periods(subscription, plan, credit, periods, last, context) do
    event = event(subscription.tenant_key, plan, credit, context)

    {counts, _previous} =
      Enum.reduce(periods, {%{}, previous_of(last)}, fn period, {acc, previous} ->
        request = request(subscription, plan, credit, period, previous, context)
        {outcome, next} = apply_period(event, request, context)
        {merge(acc, outcome), next || previous}
      end)

    counts
  end

  defp apply_period(event, request, %{dry_run: true}) do
    carry = min(unused(event.tenant_key, previous_key(request)), previous_cap(request))
    result = if request.historical?, do: :issued_and_expired, else: :granted

    emit(event, request, {result, nil}, {request.policy.amount, carry})

    counts =
      %{}
      |> count(Atom.to_string(result))
      |> add("amount", request.policy.amount)
      |> add("rollover", carry)

    {counts, nil}
  end

  defp apply_period(event, request, _context) do
    case Ledger.recurrence(event.tenant_key, request) do
      # The conflict guard refused the period: another scheduler has it. It is a
      # duplicate rather than a skip, because the period **was** granted, just
      # not by this run.
      {:ok, %{result: :skipped, reason: :duplicate}} ->
        emit(event, request, {:duplicate, :conflict}, {0, 0})
        {%{} |> count("duplicate") |> count("conflict"), nil}

      {:ok, %{result: :skipped, reason: reason}} ->
        emit(event, request, {:skipped, reason}, {0, 0})
        {skip(%{}, reason), nil}

      {:ok, report} ->
        emit(event, request, {report.result, nil}, {report.amount, report.rollover_amount})
        {period_counts(report), next_previous(report, request)}

      {:error, reason} ->
        warn_period(event.tenant_key, request, reason)
        emit(event, request, {:failed, reason_tag(reason)}, {0, 0})
        {count(%{}, "failed"), nil}
    end
  end

  defp period_counts(report) do
    %{}
    |> count(Atom.to_string(report.result))
    |> add("amount", report.amount)
    |> add("rollover", report.rollover_amount)
  end

  defp next_previous(report, request),
    do: %{id: report.recurrence.id, key: request.key, rollover: request.policy.rollover}

  defp previous_of(nil), do: nil

  defp previous_of(last),
    do: %{id: last.id, key: last.key, rollover: stored_rollover(last.policy)}

  defp previous_key(%{previous: nil}), do: nil
  defp previous_key(%{previous: %{key: key}}), do: key

  defp previous_cap(%{previous: nil}), do: 0
  defp previous_cap(%{previous: %{rollover: cap}}), do: cap

  # The cap is the previous period's own, read from the row it was stored on.
  # Reading `credit.rollover` here instead would let a plan edit change what an
  # already-issued period may carry out of itself, which is exactly what the
  # policy snapshot exists to prevent.
  defp stored_rollover(%{"rollover" => rollover}) when is_integer(rollover) and rollover >= 0,
    do: rollover

  defp stored_rollover(_policy), do: 0

  # -- the request ------------------------------------------------------------

  defp request(subscription, plan, credit, period, previous, context) do
    {version, credit} = policy_for(subscription, plan, credit, period.start, context)
    key = key(credit.name, plan.id, version, period.start)
    name = Atom.to_string(credit.name)

    %{
      key: key,
      reference: reference(subscription.tenant_key, key),
      policy: credit,
      policy_json: policy_json(credit),
      period: period,
      historical?: DateTime.compare(period.end, context.now) != :gt,
      previous: previous,
      source: %{
        "recurrence_key" => key,
        "recurrence" => name,
        "plan_id" => Atom.to_string(plan.id),
        "plan_version" => version
      },
      metadata: %{
        "recurrence" => name,
        "period_start" => DateTime.to_iso8601(period.start),
        "period_end" => DateTime.to_iso8601(period.end)
      },
      gate: gate(subscription)
    }
  end

  # The version a period was sold under, and that version's own policy (build
  # unit 07c, task 07.08).
  #
  # The catch-up case is the one this exists for: three missed periods either
  # side of an upgrade are three different contracts, and granting all three at
  # today's amount would pay a customer for months they were not on today's
  # plan. A version whose declaration no longer carries this entitlement, or
  # which resolves to neither code nor a snapshot, keeps the caller's policy:
  # the tenant is owed the allowance their current contract declares, and
  # withdrawing it because an old definition is unreadable would be a worse
  # answer than paying it.
  @spec policy_for(Subscription.t(), Plan.t(), Plan.recurring_credit(), DateTime.t(), map()) ::
          {String.t(), Plan.recurring_credit()}
  defp policy_for(subscription, plan, credit, at, context) do
    version = version_for(subscription, plan, at, context)
    {version, policy_of(plan, version, credit)}
  end

  defp policy_of(%Plan{version: version}, version, credit), do: credit

  defp policy_of(%Plan{id: id}, version, credit) do
    with %Plan{recurring_credits: credits} <- Plans.get(id, version),
         %{} = declared <- Enum.find(credits, &(&1.name == credit.name)) do
      declared
    else
      _unreadable_or_undeclared -> credit
    end
  end

  # The version this period was sold under (build unit 07c, task 07.08).
  #
  # The plan id is **pinned**, not just read. `effective_for/2` answers with a
  # pair, and a historical period may belong to a different plan entirely; using
  # that plan's version number for this plan's key would mint a key naming a
  # contract that never existed. A pair for another plan therefore falls back
  # exactly as an unresolved one does.
  #
  # Two nodes sweeping the same period agree, which is what keeps the `UNIQUE
  # (tenant_key, key)` guard meaningful: before a transition applies both read
  # the current assignment, and after it applies both take the historic branch,
  # whose `from` side is the same pair the current assignment used to be.
  @spec version_for(Subscription.t(), Plan.t(), DateTime.t(), map()) :: String.t()
  defp version_for(%Subscription{} = subscription, plan, at, _context) do
    plan_id = plan.id

    case Plans.effective_for(subscription.tenant_key, at) do
      {:ok, {^plan_id, version}} -> version
      _other_plan_or_unresolved -> subscription.plan_version || @default_version
    end
  end

  # Re-read and re-checked inside the balance row lock, because the scan's
  # snapshot is a moment old and a subscription cancelled or switched since is
  # not owed the next period's allowance. The subscription row is read, never
  # locked: locking it would add a second lock order, and a transition that
  # lands mid-transaction is build unit 07b's to order, not this one's.
  defp gate(%Subscription{tenant_key: tenant_key, plan_id: plan_id}) do
    fn _repo -> still_entitled?(Storage.get_subscription(tenant_key), plan_id) end
  end

  defp still_entitled?(%Subscription{plan_id: plan_id} = current, plan_id) do
    if Subscription.entitled?(current), do: :ok, else: {:skip, :not_entitled}
  end

  defp still_entitled?(%Subscription{}, _plan_id), do: {:skip, :plan_changed}
  defp still_entitled?(nil, _plan_id), do: {:skip, :not_entitled}

  @doc false
  # The per-tenant recurrence key. `UNIQUE (tenant_key, key)` carries the tenant,
  # so this one does not; `reference/2` does, because the ledger's index does
  # not. See `AuroraMeter.Schema.CreditRecurrence`.
  @spec key(atom(), atom(), String.t(), DateTime.t()) :: String.t()
  def key(name, plan_id, version, period_start) do
    "recurring:" <>
      Atom.to_string(name) <>
      ":" <>
      Atom.to_string(plan_id) <>
      ":" <> version <> ":" <> DateTime.to_iso8601(period_start)
  end

  @doc false
  # The ledger's idempotency key for the period's grant.
  # `aurora_meter_credit_transactions` is unique on `(kind, reference)` across
  # every tenant in the installation, so two tenants on one plan reaching one
  # period would collide on the recurrence key alone (`open-findings.md` X273).
  @spec reference(String.t(), String.t()) :: String.t()
  def reference(tenant_key, key),
    do: String.replace_prefix(key, @namespace, @namespace <> tenant_key <> ":")

  defp policy_json(credit) do
    %{
      "amount" => credit.amount,
      "category" => Atom.to_string(credit.category),
      "rollover" => credit.rollover,
      "expires" => expires_json(credit.expires)
    }
  end

  defp expires_json({:seconds, seconds}), do: %{"seconds" => seconds}
  defp expires_json(expires), do: Atom.to_string(expires)

  # -- the period walk --------------------------------------------------------

  defp collect(_tenant, _period, _current, 0, acc), do: {:ok, Enum.reverse(acc), :truncated}

  defp collect(tenant, period, current, budget, acc) do
    next = Period.containing(tenant, period.end)

    cond do
      # A custom source that answers with the same window for an instant past
      # its own end would loop for ever. It is skipped and reported instead.
      DateTime.compare(next.start, period.start) != :gt ->
        {:error, :period_source_stalled}

      DateTime.compare(next.start, current.start) == :lt ->
        collect(tenant, next, current, budget - 1, [next | acc])

      true ->
        # `next` has reached the live period, or a source whose shape changed has
        # stepped past it. Either way the live period is `current`, which is the
        # one the source says holds `now`.
        {:ok, Enum.reverse([current | acc]), :complete}
    end
  end

  # -- reads ------------------------------------------------------------------

  defp last_recurrence(tenant_key, name) do
    Config.repo().one(
      from(r in CreditRecurrence,
        where:
          r.tenant_key == ^tenant_key and
            fragment("split_part(?, ':', 2)", r.key) == ^Atom.to_string(name),
        order_by: [desc: r.period_start],
        limit: 1
      )
    )
  end

  defp recurrences_of(nil, _limit), do: []

  defp recurrences_of(tenant, limit) do
    tenant_key = Tenant.to_key(tenant)

    Config.repo().all(
      from(r in CreditRecurrence,
        where: r.tenant_key == ^tenant_key,
        order_by: [desc: r.period_start],
        limit: ^limit
      )
    )
  end

  @doc false
  # Read without a lock, for `:dry_run` and for support tooling. The reading a
  # grant is taken from is the locked one in `AuroraMeter.Credits.Ledger`.
  @spec unused(String.t(), String.t() | nil) :: non_neg_integer()
  def unused(_tenant_key, nil), do: 0

  def unused(tenant_key, recurrence_key) do
    Config.repo().one(
      from(l in CreditLot,
        where:
          l.tenant_key == ^tenant_key and
            fragment("?->>'recurrence_key'", l.source) == ^recurrence_key,
        select: coalesce(sum(l.available + l.expired), 0)
      )
    ) || 0
  end

  @doc false
  # Whether the allocator will own this wallet when the grant writes to it.
  #
  # Three cases, and the third is the one repair unit R6 added (`open-findings.md`
  # X380):
  #
  #   * the wallet has `lots_enabled_at` set: the allocator owns it, true;
  #   * the wallet exists with the flag null: a wallet that predates the
  #     lots-on-creation release and has not been migrated, false, and it is
  #     skipped with `reason: :lots_disabled` exactly as before;
  #   * **there is no wallet row at all: true**, because the grant this gate is
  #     deciding about is what creates it, and `Ledger.locked_row/2` stamps
  #     `lots_enabled_at` on the insert that does.
  #
  # Without the third case a recurring allowance could never reach a customer
  # who had never been granted anything, which is every customer at the moment
  # they subscribe, and an allowance is usually the first credit a wallet ever
  # sees. The gate would have been circular: the wallet needs a grant to exist,
  # and the grant needs the wallet to exist.
  #
  # This is a pre-filter that saves a transaction per period. The reading that
  # decides is still the locked one in `AuroraMeter.Credits.Ledger`, so a wallet
  # created between this read and that lock is judged there, on its real flag,
  # under the row lock.
  @spec lots?(String.t()) :: boolean()
  def lots?(tenant_key) do
    case Config.repo().one(
           from(b in CreditBalance,
             where: b.tenant_key == ^tenant_key,
             select: b.lots_enabled_at
           )
         ) do
      nil ->
        not wallet_exists?(tenant_key)

      _stamped ->
        true
    end
  end

  @spec wallet_exists?(String.t()) :: boolean()
  defp wallet_exists?(tenant_key) do
    Config.repo().one(from(b in CreditBalance, where: b.tenant_key == ^tenant_key, select: true)) ||
      false
  end

  # -- telemetry and counters -------------------------------------------------

  defp emit(event, request, {result, reason}, {amount, rollover}) do
    :telemetry.execute(
      [:aurora_meter, :credits, :recurrence],
      %{amount: amount, rollover_amount: rollover},
      Map.merge(event, %{
        period_start: request && request.period.start,
        result: result,
        reason: reason
      })
    )
  end

  defp count(counts, key), do: Map.update(counts, key, 1, &(&1 + 1))

  defp add(counts, _key, 0), do: counts
  defp add(counts, key, amount), do: Map.update(counts, key, amount, &(&1 + amount))

  defp skip(counts, reason) do
    counts
    |> count("skipped")
    |> count("skipped:" <> to_string(reason))
  end

  defp note_catching_up(counts, :complete), do: counts
  defp note_catching_up(counts, :truncated), do: count(counts, "catching_up")

  defp merge(acc, added) do
    Map.merge(acc, added, fn
      _key, a, b when is_number(a) and is_number(b) -> a + b
      _key, _a, b -> b
    end)
  end

  defp reason_tag({:period_source_error, _exception}), do: :period_source_error
  defp reason_tag(reason) when is_atom(reason), do: reason
  defp reason_tag(_reason), do: :failed

  defp warn_source(tenant_key, name, reason) do
    Logger.warning(
      "AuroraMeter.Credits.Recurrences: the period source could not place " <>
        "#{inspect(tenant_key)} for #{inspect(name)} (#{inspect(reason_tag(reason))}). The " <>
        "tenant is skipped and the run continues; nothing is granted for it until the " <>
        "source is fixed. #{detail(reason)}"
    )
  end

  defp detail({:period_source_error, exception}) when is_exception(exception),
    do: Exception.message(exception)

  defp detail(_reason), do: ""

  defp warn_period(tenant_key, request, reason) do
    Logger.warning(
      "AuroraMeter.Credits.Recurrences: #{inspect(request.key)} failed for " <>
        "#{inspect(tenant_key)} with #{inspect(reason)}. Nothing was written for that " <>
        "period; the next run examines it again."
    )
  end
end
