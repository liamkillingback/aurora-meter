defmodule AuroraMeter.Test.LedgerModel do
  @moduledoc """
  A pure, sequential model of `AuroraMeter.Credits` (build unit 01e).

  `apply/2` takes a model and one command and returns `{model, expected}`: the
  state the ledger should be in afterwards and the value the ledger should have
  returned. `AuroraMeter.Test.LedgerCommands.run/2` issues the same command
  against the real database and compares both after **every** step, so a
  disagreement names the command that caused it.

  ## Why this is a reimplementation and not a delegation

  The model never calls the ledger's arithmetic
  (`lib/aurora_meter/credits/ledger.ex`) or its attribution fold
  (`lib/aurora_meter/credits/promotions.ex`), both of which are internal. A model
  that delegated would agree with the code by construction and would prove
  nothing. Every rule below is written out
  from the specification and carries, in a comment, the `lib/` line it mirrors,
  so review is a line-by-line comparison rather than a judgement.

  ## Three things the model deliberately does not know

    * **Time.** `inserted_at` is stamped from `DateTime.utc_now()` inside
      `Ledger.apply_entry/3` (`ledger.ex:452`). The model never predicts a
      timestamp, only an order: `seq` increments once per written entry, which
      matches the real `(inserted_at, id)` order because one process issues one
      command at a time and every command is a separate database round trip.
      Two entries sharing a microsecond would break that correspondence; the
      generator cannot produce them, and `docs/evidence/v1/phase-01/i10.md`
      records the assumption.
    * **Identity.** A grant's real identity is a UUID. The model keys grants by
      their reference, which is unique per history. The ledger's ordering
      tie-break "then id" (`promotions.ex:53`) therefore has no model
      counterpart; it is only reachable when two grants share an `inserted_at`
      microsecond, which the point above excludes.
    * **Generated references.** `Ledger.expire_reference/2`
      (`ledger.ex:354-357`) builds `"expire:<uuid>"` or, for a partial expiry,
      appends `System.unique_integer/1` (finding L7). The model records a
      synthetic marker instead and never asserts on the real string.

  ## Configuration

  The overdraft tolerance is a field, read once when the history starts, never
  at apply time. A mid-history configuration change would otherwise
  desynchronise the two implementations silently.

  ## Known defects this model reproduces

  It encodes the ledger **as it is today**, not as it should be. Each of these
  is current behaviour with a finding id and the unit that changes it:

    * **L1** a release after a partial expiry returns expired value to the
      spendable balance (`lot_view/1` measures the difference; 06a).
    * **L2** `reverse/4` and `debit/4` share the `:debit` reference namespace
      (`credits.ex:329-335`, `ledger.ex:221`; 06c).
    * **L7** a partial expiry writes a fresh reference every pass, so it is not
      idempotent (`ledger.ex:356-357`; 06a).
    * **L12** `expire_due/1` truncates `now` to whole seconds
      (`ledger.ex:249`; INFO).
    * **L14** `debit` rows carry `category: nil` (`ledger.ex:205`; 06a).
    * **L16** a settlement above its hold takes the balance negative and is only
      flagged in telemetry (`ledger.ex:167`; 06a).
    * **L19** `expire_due/1` selects due grants with no `order_by`
      (`ledger.ex:251-259`), so the split between two grants due in one pass is
      undefined. `due_grants/2` below picks the D07 order; the generator never
      produces more than one due grant, and one named test records the
      ambiguity.

  ## The dormant lot view

  `lot_view/1` projects the same history onto the lot design in
  `docs/v1/build-plans/architecture-map.md` section 7, which 06a will build. It
  is computed but not compared against the database, because there are no lot
  tables yet; only **V8** (`v8_problems/1`, its own internal conservation) is
  asserted. The gap between its spendable figure and the flat ledger's is the L1
  leak, and `lot_view/1` reports it as `:leak`.
  """

  # `apply/2` is the contract's name for the model's one entry point. The
  # explicit exclusion keeps `Kernel.apply/2` unambiguous inside this module
  # rather than relying on the implicit shadowing rule.
  import Kernel, except: [apply: 2]

  @type category :: :paid | :promotional | :adjustment
  @type ref :: String.t()

  @type command ::
          {:grant, ref(), pos_integer(), category(), DateTime.t() | nil}
          | {:hold, ref(), pos_integer()}
          | {:settle, ref(), non_neg_integer()}
          | {:release, ref()}
          | {:debit, ref(), pos_integer()}
          | {:reverse, ref(), pos_integer()}
          | {:expire_due, DateTime.t()}

  @type result ::
          :ok
          | {:ok, :new | :duplicate}
          | {:ok, non_neg_integer()}
          | {:error,
             :insufficient_credits
             | :duplicate_reference
             | :not_found
             | :already_settled
             | :held
             | :already_expired}

  @type t :: %__MODULE__{}

  defstruct tolerance: 0,
            currency: "usd",
            low_balance_threshold: nil,
            balance: 0,
            held: 0,
            promotional: 0,
            # Always 0 before 06a. The fields exist so 06a adds no shape change.
            debt: 0,
            expired: 0,
            seq: 0,
            # Every written entry, oldest first, with its computed figures.
            entries: [],
            # Every attempted command with the result the model predicted,
            # refusals included. `lot_view/1` replays this.
            commands: [],
            # reference => %{amount, status, settled_amount, overrun?}
            holds: %{},
            # reference => %{seq, amount, remaining, expires_at, expired_at}
            grants: %{},
            # {namespace, reference}; `:reverse` shares `:debit` (L2)
            refs: MapSet.new(),
            # Built by `lot_view/1`; the field exists for 06a's shape.
            lots: []

  @doc """
  A fresh model. `:tolerance` is
  `AuroraMeter.Config.credits_overdraft_tolerance/0` read once by the caller,
  `:currency` is `credits_currency/0`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      tolerance: Keyword.get(opts, :tolerance, 0),
      currency: Keyword.get(opts, :currency, "usd")
    }
  end

  # -- the seven commands -----------------------------------------------------

  @doc """
  Applies one command, returning the new model and the result the real ledger is
  expected to return.
  """
  @spec apply(t(), command()) :: {t(), result()}
  def apply(%__MODULE__{} = model, command) do
    {next, result} = step(model, command)
    {%{next | commands: next.commands ++ [%{command: command, result: result}]}, result}
  end

  # grant: the reference is checked inside the balance row's lock and a hit
  # returns the existing row untouched (`ledger.ex:96-98`, `:112`).
  defp step(model, {:grant, reference, amount, category, expires_at}) do
    if MapSet.member?(model.refs, {:grant, reference}) do
      {model, {:ok, :duplicate}}
    else
      entry = %{
        kind: :grant,
        category: category,
        amount: amount,
        held_delta: 0,
        reference: reference,
        expires_at: expires_at
      }

      {model |> write(entry) |> register(:grant, reference), {:ok, :new}}
    end
  end

  # hold: duplicate first, then sufficiency, in that order (`ledger.ex:124-131`).
  defp step(model, {:hold, reference, amount}) do
    cond do
      MapSet.member?(model.refs, {:hold, reference}) ->
        {model, {:error, :duplicate_reference}}

      not sufficient?(model, amount) ->
        {model, {:error, :insufficient_credits}}

      true ->
        entry = %{
          kind: :hold,
          category: nil,
          amount: 0,
          held_delta: amount,
          reference: reference,
          status: :pending
        }

        model =
          model
          |> write(entry)
          |> register(:hold, reference)
          |> put_hold(reference, amount)

        {model, :ok}
    end
  end

  # settle: the hold row is found and locked first, so an unknown reference is
  # `:not_found` and a closed one `:already_settled` before the balance row is
  # touched at all (`ledger.ex:149-154`, `:506-518`).
  defp step(model, {:settle, reference, actual}) do
    with_pending_hold(model, reference, fn hold ->
      entry = %{
        kind: :settle,
        category: nil,
        amount: -actual,
        held_delta: -hold.amount,
        reference: reference,
        settled_amount: actual
      }

      model
      |> write(entry)
      |> close_hold(reference, :settled, actual, actual > hold.amount)
    end)
  end

  # release: the same guards; the entry moves `held` only (`ledger.ex:183-191`).
  defp step(model, {:release, reference}) do
    with_pending_hold(model, reference, fn hold ->
      entry = %{
        kind: :release,
        category: nil,
        amount: 0,
        held_delta: -hold.amount,
        reference: reference
      }

      model
      |> write(entry)
      |> close_hold(reference, :released, nil, false)
    end)
  end

  # debit: duplicate first, then sufficiency (`ledger.ex:220-225`). `category`
  # stays nil on a plain debit, which is finding L14.
  defp step(model, {:debit, reference, amount}) do
    cond do
      MapSet.member?(model.refs, {:debit, reference}) ->
        {model, {:error, :duplicate_reference}}

      not sufficient?(model, amount) ->
        {model, {:error, :insufficient_credits}}

      true ->
        {model |> write(spend_entry(reference, amount, nil)) |> register(:debit, reference), :ok}
    end
  end

  # reverse: `Credits.reverse/4` delegates to `Ledger.debit/5` with
  # `allow_negative: true, category: :reversal` (`credits.ex:329-335`), so it
  # writes a `:debit` row and shares that reference namespace. That is finding
  # L2, reproduced here rather than corrected.
  defp step(model, {:reverse, reference, amount}) do
    if MapSet.member?(model.refs, {:debit, reference}) do
      {model, {:error, :duplicate_reference}}
    else
      entry = spend_entry(reference, amount, :reversal)
      {model |> write(entry) |> register(:debit, reference), :ok}
    end
  end

  # expire_due: one transaction per due grant, and the return value counts the
  # ones that produced an entry (`ledger.ex:247-267`).
  defp step(model, {:expire_due, now}) do
    now = DateTime.truncate(now, :second)

    {model, count} =
      model
      |> due_grants(now)
      |> Enum.reduce({model, 0}, fn key, {acc, count} ->
        case expire_one(acc, key, now) do
          {:expired, acc} -> {acc, count + 1}
          {:refused, acc} -> {acc, count}
        end
      end)

    {model, {:ok, count}}
  end

  defp spend_entry(reference, amount, category) do
    %{kind: :debit, category: category, amount: -amount, held_delta: 0, reference: reference}
  end

  defp with_pending_hold(model, reference, fun) do
    case Map.fetch(model.holds, reference) do
      :error -> {model, {:error, :not_found}}
      {:ok, %{status: :pending} = hold} -> {fun.(hold), :ok}
      {:ok, _closed} -> {model, {:error, :already_settled}}
    end
  end

  # -- expiry -----------------------------------------------------------------

  # `ledger.ex:251-259` selects the due grant ids with no `order_by`, so the
  # database's order is undefined (finding L19). The model has to pick one; it
  # picks D07's, which is what 06a must add to the query. The generator never
  # produces a history with two grants due in one pass, and
  # `credits_model_test.exs` records the ambiguity in its own named test.
  defp due_grants(model, now) do
    model.grants
    |> Map.values()
    |> Enum.filter(&due?(&1, now))
    |> Enum.sort_by(&{expiry_key(&1.expires_at), &1.seq})
    |> Enum.map(& &1.reference)
  end

  defp due?(%{expires_at: nil}, _now), do: false
  defp due?(%{expired_at: stamped}, _now) when not is_nil(stamped), do: false
  defp due?(%{expires_at: expires_at}, now), do: DateTime.compare(expires_at, now) != :gt

  # `expire_locked/3` (`ledger.ex:284-327`): never claw back what a hold has
  # reserved, never push the balance below zero, and leave `expired_at` unset
  # when only part of the grant could be taken.
  defp expire_one(model, key, now) do
    grant = Map.fetch!(model.grants, key)
    spendable = max(model.balance - model.held, 0)
    amount = [grant.remaining, model.promotional, spendable] |> Enum.min() |> max(0)
    fully_expired? = amount >= grant.remaining

    if amount == 0 and not fully_expired? do
      # `ledger.ex:304-305`: entirely spoken for by a hold, so no row at all.
      {:refused, model}
    else
      entry = %{
        kind: :expire,
        category: :promotional,
        amount: -amount,
        held_delta: 0,
        reference: expire_marker(key, fully_expired?),
        grant_key: key
      }

      {:expired, model |> write(entry) |> stamp_expired(key, fully_expired?, now)}
    end
  end

  # The model never predicts the real reference, which carries the grant's UUID
  # and, for a partial expiry, `System.unique_integer/1` (`ledger.ex:354-357`,
  # finding L7). This marker exists so the entry log reads sensibly.
  defp expire_marker(key, true), do: "expire:" <> key
  defp expire_marker(key, false), do: "expire:" <> key <> ":partial"

  defp stamp_expired(model, _key, false, _now), do: model

  defp stamp_expired(model, key, true, now) do
    # `ledger.ex:321-323`: stamped only when the whole remainder went.
    %{model | grants: Map.update!(model.grants, key, &%{&1 | expired_at: now})}
  end

  # -- the write path ---------------------------------------------------------

  # Mirrors `Ledger.apply_entry/3` (`ledger.ex:433-471`): the three figures are
  # computed from the row as it was, in this order.
  defp write(model, attrs) do
    held_delta = Map.get(attrs, :held_delta, 0)
    # ledger.ex:436
    balance_after = model.balance + attrs.amount
    # ledger.ex:437
    held_after = model.held + held_delta

    # ledger.ex:439-444
    promotional_after =
      model.promotional
      |> promotional_delta(attrs)
      |> min(max(balance_after, 0))
      |> max(0)

    entry =
      Map.merge(attrs, %{
        seq: model.seq + 1,
        held_delta: held_delta,
        balance_after: balance_after,
        held_after: held_after,
        promotional_after: promotional_after
      })

    %{
      model
      | balance: balance_after,
        held: held_after,
        promotional: promotional_after,
        seq: entry.seq,
        grants: attribute(model.grants, entry, model.promotional),
        entries: model.entries ++ [entry]
    }
  end

  # Mirrors `Ledger.promotional_delta/2` (`ledger.ex:473-486`), clause for
  # clause and in the same order. The `:reversal` clause is the one that
  # matters: a refund must not quietly consume a trial grant
  # (`ledger.ex:477-481`).
  defp promotional_delta(promotional, %{kind: :grant, category: :promotional, amount: amount}),
    do: promotional + amount

  defp promotional_delta(promotional, %{category: :reversal}), do: promotional

  defp promotional_delta(promotional, %{amount: amount}) when amount < 0,
    do: promotional + amount

  defp promotional_delta(promotional, _attrs), do: promotional

  # `ledger.ex:488-490`. The tolerance is the model's field, not a config read.
  defp sufficient?(model, amount), do: model.balance - model.held + model.tolerance >= amount

  # -- per-grant attribution --------------------------------------------------

  # An independent rewrite of `AuroraMeter.Credits.Promotions`, which the model
  # must never call. `total` is the promotional figure *before* this entry, the
  # same running total the real fold carries.

  # promotions.ex:18-29: a promotional grant contributes only what the balance
  # after it leaves room for.
  defp attribute(grants, %{kind: :grant, category: :promotional} = entry, total) do
    added = min(entry.amount, max(entry.balance_after - total, 0))

    Map.put(grants, entry.reference, %{
      reference: entry.reference,
      seq: entry.seq,
      amount: entry.amount,
      remaining: added,
      expires_at: entry.expires_at,
      expired_at: nil
    })
  end

  # promotions.ex:31-40: a negative entry consumes the difference between the
  # running total before and after it. A reversal is clamped by the balance
  # rather than reduced by its own amount.
  defp attribute(grants, %{amount: amount} = entry, total) when amount < 0 do
    after_total =
      if Map.get(entry, :category) == :reversal,
        do: min(total, max(entry.balance_after, 0)),
        else: max(total + amount, 0)

    consume(grants, total - after_total, Map.get(entry, :grant_key))
  end

  # promotions.ex:42: everything else leaves attribution alone.
  defp attribute(grants, _entry, _total), do: grants

  # promotions.ex:44-46: an expiry names its grant, so it consumes only that one.
  defp consume(grants, amount, key) when is_binary(key) do
    Map.update!(grants, key, &%{&1 | remaining: max(&1.remaining - amount, 0)})
  end

  # promotions.ex:48-61: everything else spends soonest-expiring first, then
  # oldest, with non-expiring grants last.
  defp consume(grants, amount, nil) do
    grants
    |> Map.values()
    |> Enum.sort_by(&{expiry_key(&1.expires_at), &1.seq})
    |> Enum.reduce({grants, amount}, fn grant, {acc, left} ->
      taken = min(grant.remaining, left)
      {Map.put(acc, grant.reference, %{grant | remaining: grant.remaining - taken}), left - taken}
    end)
    |> elem(0)
  end

  # promotions.ex:63-64.
  defp expiry_key(nil), do: {1, 0}
  defp expiry_key(datetime), do: {0, DateTime.to_unix(datetime)}

  # -- bookkeeping ------------------------------------------------------------

  defp register(model, namespace, reference),
    do: %{model | refs: MapSet.put(model.refs, {namespace, reference})}

  defp put_hold(model, reference, amount) do
    hold = %{amount: amount, status: :pending, settled_amount: nil, overrun?: false}
    %{model | holds: Map.put(model.holds, reference, hold)}
  end

  defp close_hold(model, reference, status, settled_amount, overrun?) do
    holds =
      Map.update!(model.holds, reference, fn hold ->
        %{hold | status: status, settled_amount: settled_amount, overrun?: overrun?}
      end)

    %{model | holds: holds}
  end

  # -- projections ------------------------------------------------------------

  @doc """
  The six financial figures. `:debt` and `:expired` are always zero before 06a;
  they are here so 06a adds no shape change.
  """
  @spec projections(t()) :: map()
  def projections(model) do
    %{
      balance: model.balance,
      held: model.held,
      available: model.balance - model.held,
      promotional: model.promotional,
      debt: model.debt,
      expired: model.expired
    }
  end

  @doc """
  The model's prediction in the exact shape `AuroraMeter.Credits.balance/1`
  returns (`credits.ex:142-175`), so the comparison is one map equality.
  """
  @spec wallet(t()) :: map()
  def wallet(model) do
    %{
      balance: model.balance,
      held: model.held,
      available: model.balance - model.held,
      promotional: model.promotional,
      currency: model.currency,
      low_balance_threshold: model.low_balance_threshold
    }
  end

  @doc "Open (still pending) holds as `reference => reserved amount`."
  @spec open_holds(t()) :: map()
  def open_holds(model) do
    for {reference, %{status: :pending, amount: amount}} <- model.holds,
        into: %{},
        do: {reference, amount}
  end

  @doc "What the model says is left of the promotional grant under `reference`."
  @spec remaining(t(), ref()) :: non_neg_integer()
  def remaining(model, reference) do
    case Map.fetch(model.grants, reference) do
      {:ok, grant} -> grant.remaining
      :error -> 0
    end
  end

  @doc "Every promotional grant's remainder, as `reference => remaining`."
  @spec remainders(t()) :: map()
  def remainders(model),
    do: Map.new(model.grants, fn {reference, grant} -> {reference, grant.remaining} end)

  @doc "Closed holds as `reference => %{status, settled_amount, overrun?}`."
  @spec closed_holds(t()) :: map()
  def closed_holds(model) do
    for {reference, %{status: status} = hold} <- model.holds,
        status != :pending,
        into: %{},
        do: {reference, Map.take(hold, [:status, :settled_amount, :overrun?])}
  end

  @doc """
  The model's own conservation laws, as a list of `{invariant, problem}` pairs;
  empty when the model is self-consistent. Checked after every step so a model
  bug cannot masquerade as a ledger bug.
  """
  @spec self_check(t()) :: [{atom(), String.t()}]
  def self_check(model) do
    Enum.reject([v1_self(model), v2_self(model), v3_self(model), v4_self(model)], &is_nil/1)
  end

  defp v1_self(model) do
    sum = Enum.reduce(model.entries, 0, &(&1.amount + &2))
    if sum == model.balance, do: nil, else: {:v1, "model balance #{model.balance} vs #{sum}"}
  end

  defp v2_self(model) do
    sum = Enum.reduce(model.entries, 0, &(&1.held_delta + &2))
    open = model |> open_holds() |> Map.values() |> Enum.sum()

    cond do
      sum != model.held -> {:v2, "model held #{model.held} vs held_delta sum #{sum}"}
      open != model.held -> {:v2, "model held #{model.held} vs open holds #{open}"}
      true -> nil
    end
  end

  defp v3_self(model) do
    if model.promotional >= 0 and model.promotional <= max(model.balance, 0),
      do: nil,
      else: {:v3, "promotional #{model.promotional} outside 0..max(#{model.balance}, 0)"}
  end

  defp v4_self(model) do
    case List.last(model.entries) do
      nil ->
        nil

      entry ->
        actual = {entry.balance_after, entry.held_after, entry.promotional_after}
        expected = {model.balance, model.held, model.promotional}
        if actual == expected, do: nil, else: {:v4, "#{inspect(actual)} vs #{inspect(expected)}"}
    end
  end

  # -- the dormant lot view ---------------------------------------------------

  @doc """
  Projects the history onto the lot design of `architecture-map.md` section 7,
  which 06a will implement. Dormant: nothing compares it with the database,
  because there are no lot tables yet; only **V8** (`v8_problems/1`) is
  asserted.

  Returns the lots, the four scalars the replay tracks independently of them,
  and `:leak`: the micro-dollars today's flat ledger still counts as spendable
  that the lot design has already written off as expired. That difference **is**
  finding L1, measured rather than argued.

  Two deliberate simplifications, both recorded in
  `docs/evidence/v1/phase-01/i10.md`:

    * it replays the commands the flat ledger accepted, so a command 06a would
      have refused (its `sufficient?` subtracts debt) is still applied here;
    * `expire_due` is replayed with 06a's semantics whatever the flat ledger
      did, because expiring the whole available part of every due lot is exactly
      the change 06a makes.
  """
  @spec lot_view(t()) :: map()
  def lot_view(model) do
    state =
      Enum.reduce(model.commands, empty_lot_state(), fn %{command: command, result: result},
                                                        acc ->
        replay(acc, command, result)
      end)

    lot_available = state.balance - state.held

    state
    |> Map.put(:lots, Enum.sort_by(state.lots, & &1.id))
    |> Map.put(:available, lot_available)
    |> Map.put(:leak, model.balance - model.held - lot_available)
  end

  defp empty_lot_state do
    %{
      lots: [],
      debt: 0,
      balance: 0,
      held: 0,
      promotional: 0,
      expired: 0,
      # The L1 measure: value that was reserved when its lot expired and came
      # back as `expired` here, while today's ledger hands it back as spendable
      # balance. `:leak` is the raw difference between the two spendable figures
      # and also carries the other, deliberate divergences of this view (debt on
      # commands 06a would have refused, and a reversal that eats a
      # reservation); this counter is L1 and nothing else.
      released_expired: 0,
      # How much was still reserved on a lot at the moment it expired. L1 can
      # only be non-zero when this is, so a run that measures no leak can say
      # whether its histories never held a reservation across an expiry or
      # simply never closed the hold afterwards.
      expired_with_reservation: 0,
      reservations: %{}
    }
  end

  @doc """
  V8: the lot view's internal conservation. Returns a list of problems, empty
  when it holds.

  Per lot `available + reserved + consumed + reversed + expired == amount`, with
  every bucket non-negative; across lots `sum(available + reserved) - debt ==
  balance`, `sum(reserved) == held`, `sum(available + reserved over promotional
  lots) == promotional` and `sum(expired) == expired`. The scalars on the right
  are tracked by the replay independently of the buckets, so this is a
  comparison and not a tautology.
  """
  @spec v8_problems(map()) :: [String.t()]
  def v8_problems(view),
    do: Enum.reject(lot_problems(view) ++ aggregate_problems(view), &is_nil/1)

  defp lot_problems(view) do
    Enum.flat_map(view.lots, fn lot ->
      total = Enum.sum(buckets(lot))

      [
        if(total == lot.amount, do: nil, else: "lot #{lot.id}: #{total} != amount #{lot.amount}"),
        if(Enum.all?(buckets(lot), &(&1 >= 0)), do: nil, else: "lot #{lot.id}: negative bucket")
      ]
    end)
  end

  defp buckets(lot), do: [lot.available, lot.reserved, lot.consumed, lot.reversed, lot.expired]

  defp aggregate_problems(view) do
    live = Enum.reduce(view.lots, 0, &(&1.available + &1.reserved + &2))
    reserved = Enum.reduce(view.lots, 0, &(&1.reserved + &2))
    expired = Enum.reduce(view.lots, 0, &(&1.expired + &2))

    promotional =
      view.lots
      |> Enum.filter(&(&1.category == :promotional))
      |> Enum.reduce(0, &(&1.available + &1.reserved + &2))

    [
      compare("V8 balance", live - view.debt, view.balance),
      compare("V8 held", reserved, view.held),
      compare("V8 promotional", promotional, view.promotional),
      compare("V8 expired", expired, view.expired)
    ]
  end

  defp compare(_label, same, same), do: nil
  defp compare(label, lots, scalar), do: "#{label}: lots #{lots} != tracked #{scalar}"

  # -- lot replay -------------------------------------------------------------

  # 7.2: every incoming grant repays outstanding debt first, by writing a
  # `consume` allocation against the new lot.
  defp replay(state, {:grant, reference, amount, category, expires_at}, {:ok, :new}) do
    repaid = min(amount, state.debt)
    id = length(state.lots) + 1

    lot = %{
      id: id,
      reference: reference,
      category: category,
      amount: amount,
      available: amount - repaid,
      reserved: 0,
      consumed: repaid,
      reversed: 0,
      expired: 0,
      expires_at: expires_at,
      granted_at: id,
      state: :open
    }

    %{
      state
      | lots: state.lots ++ [lot],
        debt: state.debt - repaid,
        balance: state.balance + amount,
        promotional: state.promotional + promotional_share(category, amount - repaid)
    }
  end

  # 7.2: a hold reserves exact lots.
  defp replay(state, {:hold, reference, amount}, :ok) do
    {state, taken} = move(state, amount, :available, :reserved, &live_lot?/1)

    %{
      state
      | reservations: Map.put(state.reservations, reference, taken),
        held: state.held + total(taken)
    }
  end

  # 7.2: settle consumes from the reserved allocation first, unreserves the
  # remainder, and if `actual` exceeds the reservation consumes remaining
  # eligible availability and records the unavoidable remainder as debt.
  defp replay(state, {:settle, reference, actual}, :ok) do
    reserved = Map.get(state.reservations, reference, [])
    from_reservation = min(actual, total(reserved))

    state
    |> consume_reservation(reserved, from_reservation)
    |> unreserve_rest(reserved, from_reservation)
    |> settle_excess(actual - from_reservation)
    |> drop_reservation(reference)
    |> subtract_held(total(reserved))
  end

  # 7.2: reserved value released on an expired lot becomes `expired` rather than
  # `available`. That is the L1 fix, and the reason this view exists.
  defp replay(state, {:release, reference}, :ok) do
    reserved = Map.get(state.reservations, reference, [])

    state
    |> unreserve_rest(reserved, 0)
    |> drop_reservation(reference)
    |> subtract_held(total(reserved))
  end

  defp replay(state, {:debit, _reference, amount}, :ok) do
    {state, taken} = move(state, amount, :available, :consumed, &live_lot?/1)
    add_debt(state, amount - total(taken))
  end

  # 7.2: a reversal targets the paid side only, buckets in the order available,
  # consumed, reserved. Promotional lots are never touched by a paid reversal.
  defp replay(state, {:reverse, _reference, amount}, :ok) do
    {state, left} = reverse_from(state, amount, :available)
    {state, left} = reverse_from(state, left, :consumed)
    {state, left} = reverse_from(state, left, :reserved)
    add_debt(state, left)
  end

  # 7.2: expiry removes only `available`, on every due lot, and the lot is
  # expired from then on so a later release lands in `expired`.
  defp replay(state, {:expire_due, now}, _result) do
    truncated = DateTime.truncate(now, :second)

    state.lots
    |> Enum.filter(&lot_due?(&1, truncated))
    |> Enum.reduce(state, fn lot, acc -> expire_lot(acc, lot.id) end)
  end

  defp replay(state, _command, _refused), do: state

  defp lot_due?(%{state: :expired}, _now), do: false
  defp lot_due?(%{expires_at: nil}, _now), do: false
  defp lot_due?(%{expires_at: at}, now), do: DateTime.compare(at, now) != :gt

  defp expire_lot(state, id) do
    lot = find_lot(state.lots, id)

    state =
      state
      |> shift(lot, :available, :expired, lot.available)
      |> Map.update!(:expired_with_reservation, &(&1 + lot.reserved))

    %{state | lots: replace_lot(state.lots, %{find_lot(state.lots, id) | state: :expired})}
  end

  defp consume_reservation(state, reserved, amount) do
    {state, _taken} = move_listed(state, reserved, amount, :reserved, :consumed)
    state
  end

  # The remainder of a reservation goes back to `available`, unless the lot has
  # since expired, in which case it becomes `expired`: today's ledger hands it
  # back as spendable, which is finding L1.
  defp unreserve_rest(state, reserved, consumed) do
    reserved
    |> subtract_listed(consumed)
    |> Enum.reduce(state, fn %{lot_id: id, amount: amount}, acc ->
      lot = find_lot(acc.lots, id)

      if lot.state == :expired do
        acc
        |> shift(lot, :reserved, :expired, amount)
        |> Map.update!(:released_expired, &(&1 + amount))
      else
        shift(acc, lot, :reserved, :available, amount)
      end
    end)
  end

  defp settle_excess(state, 0), do: state

  defp settle_excess(state, excess) do
    {state, taken} = move(state, excess, :available, :consumed, &live_lot?/1)
    add_debt(state, excess - total(taken))
  end

  defp reverse_from(state, 0, _bucket), do: {state, 0}

  defp reverse_from(state, amount, bucket) do
    {state, taken} = move(state, amount, bucket, :reversed, &paid_lot?/1)
    {reversal_side_effect(state, bucket, taken), amount - total(taken)}
  end

  # Money already spent cannot be handed back out of the wallet, so the refund
  # becomes debt (7.2).
  defp reversal_side_effect(state, :consumed, taken), do: add_debt(state, total(taken))

  # Taking from a reservation shrinks the hold that owns it. 7.2 does not say
  # so; it is the only choice that keeps `sum(reserved) == held`, and it is
  # recorded as a finding for 06a in `docs/evidence/v1/phase-01/i10.md`.
  defp reversal_side_effect(state, :reserved, taken),
    do: state |> subtract_held(total(taken)) |> shrink_reservations(taken)

  defp reversal_side_effect(state, _available, _taken), do: state

  # -- lot bucket arithmetic --------------------------------------------------

  # Moves up to `amount` from one bucket to another across the lots `filter`
  # accepts, in the D07 spend order, and returns what came from each lot.
  defp move(state, amount, from, to, filter) do
    state.lots
    |> Enum.filter(filter)
    |> spend_order()
    |> Enum.reduce({state, [], amount}, fn lot, acc -> take_from(acc, lot.id, from, to) end)
    |> then(fn {acc, taken, _left} -> {acc, taken} end)
  end

  defp take_from({state, taken, left}, id, from, to) do
    lot = find_lot(state.lots, id)
    take = min(Map.fetch!(lot, from), left)

    if take > 0 do
      {shift(state, lot, from, to, take), taken ++ [%{lot_id: id, amount: take}], left - take}
    else
      {state, taken, left}
    end
  end

  # The same, restricted to an existing allocation list and its order.
  defp move_listed(state, listed, amount, from, to) do
    listed
    |> Enum.reduce({state, [], amount}, fn %{lot_id: id, amount: reserved}, {acc, taken, left} ->
      take = min(reserved, left)

      if take > 0 do
        acc = shift(acc, find_lot(acc.lots, id), from, to, take)
        {acc, taken ++ [%{lot_id: id, amount: take}], left - take}
      else
        {acc, taken, left}
      end
    end)
    |> then(fn {acc, taken, _left} -> {acc, taken} end)
  end

  # One move between buckets, with the three scalars the move implies. `balance`
  # is `sum(available + reserved) - debt`, so a move out of the live pair lowers
  # it and a move into it raises it; `promotional` is the same sum restricted to
  # promotional lots; `expired` counts what landed in the expired bucket.
  defp shift(state, lot, from, to, amount) do
    updated = lot |> Map.update!(from, &(&1 - amount)) |> Map.update!(to, &(&1 + amount))
    delta = live_delta(from, to, amount)

    %{
      state
      | lots: replace_lot(state.lots, updated),
        balance: state.balance + delta,
        promotional: state.promotional + promotional_share(lot.category, delta),
        expired: state.expired + if(to == :expired, do: amount, else: 0)
    }
  end

  defp live_delta(from, to, amount) do
    case {from in [:available, :reserved], to in [:available, :reserved]} do
      {true, true} -> 0
      {true, false} -> -amount
      {false, true} -> amount
      {false, false} -> 0
    end
  end

  defp subtract_listed(listed, consumed) do
    listed
    |> Enum.reduce({[], consumed}, fn %{lot_id: id, amount: amount}, {acc, left} ->
      taken = min(amount, left)
      rest = amount - taken
      {acc ++ if(rest > 0, do: [%{lot_id: id, amount: rest}], else: []), left - taken}
    end)
    |> elem(0)
  end

  defp shrink_reservations(state, taken) do
    reservations =
      Map.new(state.reservations, fn {reference, listed} ->
        {reference, Enum.reduce(taken, listed, &subtract_from_lot(&2, &1))}
      end)

    %{state | reservations: reservations}
  end

  defp subtract_from_lot(listed, %{lot_id: id, amount: amount}) do
    listed
    |> Enum.map(fn
      %{lot_id: ^id, amount: held} -> %{lot_id: id, amount: max(held - amount, 0)}
      other -> other
    end)
    |> Enum.reject(&(&1.amount == 0))
  end

  # architecture-map.md 7.2: promotional before paid (adjustment treated as
  # paid), earliest non-null `expires_at` first, then `granted_at`, then id;
  # non-expiring lots last within their category.
  defp spend_order(lots) do
    Enum.sort_by(
      lots,
      &{category_rank(&1.category), expiry_key(&1.expires_at), &1.granted_at, &1.id}
    )
  end

  defp category_rank(:promotional), do: 0
  defp category_rank(_paid_or_adjustment), do: 1

  defp live_lot?(lot), do: lot.available > 0
  defp paid_lot?(lot), do: lot.category != :promotional

  defp promotional_share(:promotional, amount), do: amount
  defp promotional_share(_category, _amount), do: 0

  defp find_lot(lots, id), do: Enum.find(lots, &(&1.id == id))
  defp replace_lot(lots, lot), do: Enum.map(lots, &if(&1.id == lot.id, do: lot, else: &1))
  defp total(listed), do: Enum.reduce(listed, 0, &(&1.amount + &2))

  defp drop_reservation(state, reference),
    do: %{state | reservations: Map.delete(state.reservations, reference)}

  defp subtract_held(state, amount), do: %{state | held: state.held - amount}

  defp add_debt(state, 0), do: state

  defp add_debt(state, amount),
    do: %{state | debt: state.debt + amount, balance: state.balance - amount}
end
