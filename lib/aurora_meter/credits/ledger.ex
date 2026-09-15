defmodule AuroraMeter.Credits.Ledger do
  @moduledoc false
  # Transactional core of `AuroraMeter.Credits`. Every public function here runs
  # one database transaction and, only after it commits, the side effects
  # (telemetry, PubSub, the low-balance hook), so a handler never observes a
  # balance that later rolled back.
  #
  # ADR: the ledger talks to the configured Ecto repo directly rather than
  # through the `AuroraMeter.Storage` behaviour. Storage abstracts *bulk,
  # idempotent* counter writes that a non-SQL adapter could reasonably
  # implement; a ledger is a row lock plus an append inside one transaction,
  # which is exactly the thing a key-value store cannot promise. Pretending
  # otherwise would give the behaviour a callback nobody else could satisfy,
  # so credits are documented as requiring the Ecto storage.
  #
  # ADR: the invariant `0 <= promotional <= max(balance, 0)` is re-established
  # after every entry. Promotional credit is consumed before paid credit, so a
  # settle/debit/expire first reduces `promotional`; a grant that lands on a
  # negative balance first repays the debt, so only the part above zero is
  # still promotional (and can later expire). This is what lets `expire_due/1`
  # never push a balance below zero.

  import Ecto.Query

  require Logger

  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Credits.Allocator
  alias AuroraMeter.Credits.Promotions
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Schema.CreditTransaction
  alias Phoenix.PubSub

  @typedoc "What one page of the expiry sweep examined. Documented on `AuroraMeter.Credits`."
  @type expiry_report :: AuroraMeter.Credits.expiry_report()

  @typep outcome :: %{
           txn: CreditTransaction.t(),
           before: CreditBalance.t(),
           after: CreditBalance.t(),
           duplicate: boolean(),
           overrun: boolean()
         }

  @doc "The PubSub topic for a tenant's credit updates."
  @spec topic(String.t()) :: String.t()
  def topic(tenant_key), do: "aurora_meter:credits:" <> tenant_key

  @doc "The balance row for `tenant_key`, or `nil` when the tenant was never touched."
  @spec fetch(String.t()) :: CreditBalance.t() | nil
  def fetch(tenant_key), do: Config.repo().get_by(CreditBalance, tenant_key: tenant_key)

  @doc "The hold with `reference`, or `nil`."
  @spec fetch_hold(String.t()) :: CreditTransaction.t() | nil
  def fetch_hold(reference) do
    Config.repo().one(
      from(t in CreditTransaction, where: t.kind == ^:hold and t.reference == ^reference)
    )
  end

  # Ordered by `(inserted_at, id)` rather than `inserted_at` alone. Two holds
  # written in the same microsecond have no order under the old key, so a
  # `:limit`ed page could skip one and repeat another and a sweep that pages
  # would never see the skipped hold at all. `id` breaks the tie; `:after`
  # carries both halves so the next page resumes exactly where the last ended.
  #
  # `inserted_at` is still the wrong column to be ordering an account of the
  # past by, because it comes from a wall clock (open finding L20). 06a moves
  # every ordering here onto `seq`; this key is a strict improvement on the same
  # column and the `:after` shape is what changes when it does.
  @spec pending_holds(keyword()) :: [CreditTransaction.t()]
  def pending_holds(opts) do
    cutoff = Keyword.fetch!(opts, :older_than)
    limit = Keyword.get(opts, :limit, 200)

    from(t in CreditTransaction,
      where: t.kind == ^:hold and t.status == ^:pending and t.inserted_at < ^cutoff,
      order_by: [asc: t.inserted_at, asc: t.id],
      limit: ^limit
    )
    |> pending_holds_tenant(Keyword.get(opts, :tenant_key))
    |> pending_holds_prefix(Keyword.get(opts, :reference_prefix))
    |> pending_holds_after(Keyword.get(opts, :after))
    |> Config.repo().all()
  end

  defp pending_holds_tenant(query, nil), do: query

  defp pending_holds_tenant(query, tenant_key),
    do: where(query, [t], t.tenant_key == ^tenant_key)

  defp pending_holds_prefix(query, nil), do: query

  defp pending_holds_prefix(query, prefix),
    do: where(query, [t], like(t.reference, ^(prefix <> "%")))

  defp pending_holds_after(query, nil), do: query

  defp pending_holds_after(query, {%DateTime{} = at, id}),
    do: where(query, [t], t.inserted_at > ^at or (t.inserted_at == ^at and t.id > ^id))

  @spec grant(String.t(), pos_integer(), keyword()) ::
          {:ok, CreditTransaction.t()} | {:error, Ecto.Changeset.t()}
  def grant(tenant_key, amount, opts) do
    case grant_with_status(tenant_key, amount, opts) do
      {:ok, txn, _status} -> {:ok, txn}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec grant_with_status(String.t(), pos_integer(), keyword()) ::
          {:ok, CreditTransaction.t(), :new | :duplicate} | {:error, Ecto.Changeset.t()}
  def grant_with_status(tenant_key, amount, opts) do
    reference = Keyword.fetch!(opts, :reference)
    category = Keyword.get(opts, :category, :paid)

    transact_outcome(fn repo ->
      row = locked_row(repo, tenant_key)

      case find(repo, tenant_key, :grant, reference) do
        %CreditTransaction{} = existing ->
          %{txn: existing, before: row, after: row, duplicate: true, overrun: false}

        nil ->
          write_grant(repo, row, amount, category, opts)
      end
    end)
    |> case do
      {:ok, %{txn: txn, duplicate: true}} -> {:ok, txn, :duplicate}
      {:ok, %{txn: txn}} -> {:ok, txn, :new}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec hold(String.t(), pos_integer(), String.t(), keyword()) ::
          {:ok, CreditTransaction.t()} | {:error, :insufficient_credits | :duplicate_reference}
  def hold(tenant_key, amount, reference, opts) do
    transact(fn repo ->
      row = locked_row(repo, tenant_key)

      metadata = Map.new(Keyword.get(opts, :metadata, %{}))

      cond do
        find(repo, tenant_key, :hold, reference) ->
          refuse(:duplicate_reference)

        lots?(row) ->
          hold_with_lots(repo, row, amount, reference, metadata)

        not sufficient?(row, amount) ->
          refuse(:insufficient_credits)

        true ->
          apply_entry(repo, row, %{
            kind: :hold,
            amount: 0,
            held_delta: amount,
            reference: reference,
            status: :pending,
            metadata: metadata
          })
      end
    end)
    |> duplicate_reference_error()
  end

  @spec settle(String.t(), non_neg_integer(), keyword()) ::
          {:ok, CreditTransaction.t()} | {:error, :not_found | :already_settled}
  def settle(reference, actual, opts) do
    expected = Keyword.get(opts, :tenant_key)
    metadata = Map.new(Keyword.get(opts, :metadata, %{}))

    transact(fn repo ->
      with {:ok, tenant_key} <- hold_tenant(repo, reference, expected),
           row = locked_row(repo, tenant_key),
           {:ok, hold} <- pending_hold(repo, reference, expected) do
        outcome = settle_entry(repo, row, hold, actual, reference, metadata)
        close_hold!(repo, hold, status: :settled, settled_amount: actual)
        %{outcome | overrun: actual > hold.held_delta}
      else
        {:error, reason} -> refuse(reason)
      end
    end)
  end

  @spec release(String.t(), keyword()) ::
          {:ok, CreditTransaction.t()} | {:error, :not_found | :already_settled}
  def release(reference, opts \\ []) do
    expected = Keyword.get(opts, :tenant_key)

    transact(fn repo ->
      with {:ok, tenant_key} <- hold_tenant(repo, reference, expected),
           row = locked_row(repo, tenant_key),
           {:ok, hold} <- pending_hold(repo, reference, expected) do
        outcome = release_entry(repo, row, hold, reference)
        close_hold!(repo, hold, status: :released)
        outcome
      else
        {:error, reason} -> refuse(reason)
      end
    end)
  end

  @spec debit(String.t(), pos_integer(), String.t(), map(), keyword()) ::
          {:ok, CreditTransaction.t()} | {:error, :insufficient_credits | :duplicate_reference}
  def debit(tenant_key, amount, reference, metadata, opts \\ []) do
    # `allow_negative` is for money that has already left the payment provider
    # — a refund, a chargeback. Refusing those for want of balance would only
    # make the ledger disagree with reality; a negative balance is the honest
    # record of a debt.
    allow_negative? = Keyword.get(opts, :allow_negative, false)
    category = Keyword.get(opts, :category)

    transact(fn repo ->
      row = locked_row(repo, tenant_key)

      entry = fn ->
        apply_entry(repo, row, %{
          kind: :debit,
          category: category,
          amount: -amount,
          reference: reference,
          metadata: Map.new(metadata)
        })
      end

      cond do
        find(repo, tenant_key, :debit, reference) ->
          refuse(:duplicate_reference)

        lots?(row) ->
          debit_with_lots(repo, row, amount, reference, Map.new(metadata), category,
            allow_negative: allow_negative?
          )

        allow_negative? ->
          entry.()

        not sufficient?(row, amount) ->
          refuse(:insufficient_credits)

        true ->
          entry.()
      end
    end)
    |> duplicate_reference_error()
  end

  @spec set_low_balance_threshold(String.t(), integer() | nil) :: {:ok, CreditBalance.t()}
  def set_low_balance_threshold(tenant_key, threshold) do
    repo = Config.repo()

    repo.transaction(fn ->
      repo
      |> locked_row(tenant_key)
      |> CreditBalance.changeset(%{low_balance_threshold: threshold})
      |> repo.update!()
    end)
  end

  @doc """
  Expires every promotional grant due at `now`, one transaction per grant.
  Returns the number of grants marked expired.

  Unbounded: it examines every due grant in one pass. `expire_due/2` is the
  bounded form.
  """
  @spec expire_due(DateTime.t()) :: {:ok, non_neg_integer()}
  def expire_due(now) do
    {:ok, report} = expire_due(now, [])
    {:ok, report.expired}
  end

  @doc """
  One bounded page of the expiry sweep, from a keyset cursor.

  Options:

    * `:limit` - the most grants to examine. `nil` (the default) examines every
      due grant, which is what `expire_due/1` does.
    * `:after` - `{expires_at, id}` of the last grant the previous page
      examined.

  Returns `{:ok, report}` where `report` is `%{examined:, expired:, skipped:,
  cursor:}`. `cursor` is `{expires_at, id}` when the page came back full and
  `nil` when it did not, so a caller that pages knows whether more work is
  waiting. `skipped` counts a grant the ledger refused: already expired (another
  run reached it first) or wholly covered by a pending hold.

  ## Two things the cursor is not

  It is **not** a record of what was expired. A grant `expire_locked/3` refuses
  with `:held` is counted in `skipped` and the cursor moves past it, so it is not
  examined again *within this scan*. That is correct because the cursor is
  discarded when the scan completes, and the next run recomputes the candidate
  set from a fresh `now`, at which point the grant is a candidate again.

  It is **not** a substitute for pinning `now`. The candidate set is defined by
  a moving predicate (`expires_at <= now`), so a resumed scan that recomputed
  `now` would be scanning a different set from the one its cursor came from. The
  caller pins the instant: `AuroraMeter.Oban.CreditExpiry` stores it alongside
  the cursor and passes the same one back for the whole scan.
  """
  @spec expire_due(DateTime.t(), keyword()) :: {:ok, expiry_report()}
  def expire_due(now, opts) when is_list(opts) do
    now = DateTime.truncate(now, :second)
    limit = Keyword.get(opts, :limit)

    due =
      from(t in CreditTransaction,
        join: b in CreditBalance,
        on: b.tenant_key == t.tenant_key,
        where:
          is_nil(b.lots_enabled_at) and
            t.kind == ^:grant and t.category == ^:promotional and not is_nil(t.expires_at) and
            t.expires_at <= ^now and is_nil(t.expired_at),
        order_by: [asc: t.expires_at, asc: t.id],
        select: {t.id, t.expires_at}
      )
      |> expire_due_limit(limit)
      |> expire_due_after(Keyword.get(opts, :after))
      |> Config.repo().all()

    report =
      Enum.reduce(due, %{examined: 0, expired: 0, skipped: 0, failed: 0}, fn {id, _at}, acc ->
        acc = %{acc | examined: acc.examined + 1}

        case attempt_expiry(id, now) do
          :expired -> %{acc | expired: acc.expired + 1}
          :skipped -> %{acc | skipped: acc.skipped + 1}
          :failed -> %{acc | failed: acc.failed + 1}
        end
      end)

    cursor = expire_due_cursor(due, limit)

    # The lot phase runs once per scan, when the legacy phase has reached its
    # end, and it shares the page's budget. It carries no cursor of its own,
    # deliberately: the candidate set is recomputed from a fresh `now` on every
    # run and every lot is idempotent (a second pass finds `available = 0` and
    # is refused), so an interrupted lot phase resumes by being run again. The
    # `{expires_at, id}` cursor shape belongs to the worker's checkpoint, which
    # is 05c's, and wiring a second cursor into it is 06b's cutover work.
    report = expire_lots_phase(report, now, remaining_budget(limit, report), cursor)

    {:ok, Map.put(report, :cursor, cursor)}
  end

  defp remaining_budget(nil, _report), do: nil
  defp remaining_budget(limit, report), do: max(limit - report.examined, 0)

  defp expire_lots_phase(report, _now, 0, _cursor), do: report
  defp expire_lots_phase(report, _now, _budget, cursor) when cursor != nil, do: report

  defp expire_lots_phase(report, now, budget, _cursor) do
    from(l in CreditLot,
      where:
        l.state == ^:open and not is_nil(l.expires_at) and l.expires_at <= ^now and
          l.available > 0,
      order_by: [asc: l.expires_at, asc: l.seq],
      select: l.id
    )
    |> expire_due_limit(budget)
    |> Config.repo().all()
    |> Enum.reduce(report, fn id, acc ->
      acc = %{acc | examined: acc.examined + 1}

      case attempt_lot_expiry(id, now) do
        :expired -> %{acc | expired: acc.expired + 1}
        :skipped -> %{acc | skipped: acc.skipped + 1}
        :failed -> %{acc | failed: acc.failed + 1}
      end
    end)
  end

  # `attempt_expiry/2`'s shape, for the same reason: one wallet's fault must
  # not starve the wallets behind it, and the direction it fails in is the safe
  # one.
  defp attempt_lot_expiry(id, now) do
    case expire_lot(id, now) do
      {:ok, _txn} -> :expired
      {:error, _reason} -> :skipped
    end
  catch
    kind, reason ->
      Logger.warning(
        "AuroraMeter.Credits.expire_due/2: expiring lot #{inspect(id)} failed with " <>
          Exception.format(kind, reason, __STACKTRACE__) <>
          " The run continues; the lot is examined again next run."
      )

      :failed
  end

  @spec expire_lot(Ecto.UUID.t(), DateTime.t()) ::
          {:ok, CreditTransaction.t()} | {:error, :already_expired | :held | :not_found}
  defp expire_lot(id, now) do
    transact(fn repo ->
      case repo.one(from(l in CreditLot, where: l.id == ^id, select: l.tenant_key)) do
        nil ->
          refuse(:not_found)

        tenant_key ->
          expire_lot_for(repo, tenant_key, id, now)
      end
    end)
  end

  defp expire_lot_for(repo, tenant_key, id, now) do
    row = locked_row(repo, tenant_key)

    if lots?(row) do
      expire_lot_locked(repo, row, id, now)
    else
      refuse(:lots_disabled)
    end
  end

  defp expire_lot_locked(repo, row, id, now) do
    book = Allocator.book(repo, row.tenant_key)

    case Allocator.plan(book, {:expire, id, now}) do
      {:error, reason} ->
        refuse(reason)

      {:ok, plan} ->
        write_lot_entry(
          repo,
          row,
          book,
          %{
            kind: :expire,
            category: :promotional,
            reference: lot_expire_reference(repo, id),
            metadata: lot_expire_metadata(book, id, plan)
          },
          plan,
          now,
          :expire
        )
    end
  end

  # Idempotent by construction. `n` is the number of `expire` allocations the
  # lot already carries, read under the lot's own lock, so a retry after a
  # rollback recomputes the same reference and a retry after a lost
  # acknowledgement never gets this far: the lot's `available` is zero and the
  # planner refuses with `:already_expired`.
  #
  # It cannot collide with a 0.4.0 partial-expiry reference
  # (`expire:<grant_id>:<n>` with `n` from `System.unique_integer([:positive])`,
  # which is never zero) and it cannot collide with a completed one
  # (`expire:<grant_id>`, which has no suffix), because no lot existed before
  # schema version 9.
  defp lot_expire_reference(repo, lot_id) do
    count =
      from(a in AuroraMeter.Schema.CreditAllocation,
        where: a.lot_id == ^lot_id and a.kind == ^:expire,
        select: count(a.id)
      )
      |> repo.one()

    "expire:" <> lot_id <> ":" <> Integer.to_string(count)
  end

  defp lot_expire_metadata(book, lot_id, plan) do
    lot = Enum.find(book, &(&1.id == lot_id))
    expired = plan.movements |> Enum.map(& &1.amount) |> Enum.sum()

    %{
      "lot_id" => lot_id,
      "grant_reference" => Map.get(lot, :reference),
      "lot_amount" => lot.amount,
      "expired_amount" => expired
    }
  end

  # One grant failing is not the sweep failing. A database that cannot be
  # reached for one tenant must not starve the grants behind it, so every way
  # one transaction can end badly, a returned error, a raise from the driver, a
  # pool checkout exit, is counted and the loop goes on. The grant is still due,
  # so the next run examines it again; nothing was written.
  #
  # This is `Reconciliation.attempt/3`'s shape and `Alerts.check_all/0`'s, and
  # the direction it fails in is the safe one: a grant that was not expired is
  # money still with the tenant.
  defp attempt_expiry(id, now) do
    case expire_grant(id, now) do
      {:ok, _txn} -> :expired
      {:error, _reason} -> :skipped
    end
  catch
    kind, reason ->
      Logger.warning(
        "AuroraMeter.Credits.expire_due/2: expiring grant #{inspect(id)} failed with " <>
          Exception.format(kind, reason, __STACKTRACE__) <>
          " The run continues; the grant is examined again next run."
      )

      :failed
  end

  defp expire_due_limit(query, nil), do: query
  defp expire_due_limit(query, limit) when is_integer(limit), do: limit(query, ^limit)

  defp expire_due_after(query, nil), do: query

  defp expire_due_after(query, {%DateTime{} = at, id}),
    do: where(query, [t], t.expires_at > ^at or (t.expires_at == ^at and t.id > ^id))

  # `nil` when the page was not full, which is how a caller learns the scan
  # reached its end. An unbounded call has no cursor at all: it examined
  # everything.
  defp expire_due_cursor(_due, nil), do: nil

  defp expire_due_cursor(due, limit) do
    if length(due) < limit do
      nil
    else
      {id, expires_at} = List.last(due)
      {expires_at, id}
    end
  end

  @spec expire_grant(Ecto.UUID.t(), DateTime.t()) ::
          {:ok, CreditTransaction.t()} | {:error, :already_expired}
  defp expire_grant(id, now) do
    transact(fn repo ->
      # Balance row first, then the grant row. Today's order was the other way
      # round, and it was safe only because this path locked exactly one
      # transaction row; `architecture-map.md` 7.3 fixes one order for every
      # ledger write and this is it. The unlocked read below supplies only the
      # tenant key, which no path ever changes on a committed row; every
      # decision is still made under both locks.
      case repo.one(from(t in CreditTransaction, where: t.id == ^id, select: t.tenant_key)) do
        nil ->
          refuse(:not_found)

        tenant_key ->
          expire_grant_locked(repo, tenant_key, id, now)
      end
    end)
  end

  defp expire_grant_locked(repo, tenant_key, id, now) do
    row = locked_row(repo, tenant_key)
    grant = repo.one!(from(t in CreditTransaction, where: t.id == ^id, lock: "FOR UPDATE"))

    cond do
      # Belt and braces on the one rule that cannot be allowed to break: the
      # legacy writer and the allocator never both run on one wallet. The
      # candidate scan already excludes cut-over wallets; this refuses one that
      # was cut over between the scan and the lock.
      lots?(row) -> refuse(:lots_enabled)
      grant.expired_at -> refuse(:already_expired)
      true -> expire_locked(repo, row, grant, now)
    end
  end

  defp expire_locked(repo, row, grant, now) do
    # Never claw back credit a pending hold has already reserved. `hold/4`
    # promises the money will be there when the work settles, and expiry ran
    # straight through that promise: it took the balance below `held`, and
    # the settle that followed took the balance itself negative — which the
    # tenant then repays out of their next top-up without ever being told.
    #
    # What the hold has reserved stays. If that leaves part of the grant
    # unexpired, the grant keeps its `expired_at` unset so a later pass
    # finishes the job once the hold settles.
    spendable = max(row.balance - row.held, 0)
    remaining = remaining_on_grant(repo, grant, row)
    amount = Enum.min([remaining, row.promotional, spendable]) |> max(0)
    fully_expired? = amount >= remaining

    # Entirely spoken for by a hold: leave it alone and try again next pass,
    # rather than writing a zero-value row every half hour until the work
    # settles.
    if amount == 0 and not fully_expired? do
      refuse(:held)
    else
      outcome =
        apply_entry(repo, row, %{
          kind: :expire,
          amount: -amount,
          category: :promotional,
          reference: expire_reference(grant.id, fully_expired?),
          metadata: %{
            "grant_id" => grant.id,
            "grant_reference" => grant.reference,
            "grant_amount" => grant.amount,
            "expired_amount" => amount
          }
        })

      if fully_expired? do
        grant |> Ecto.Changeset.change(expired_at: now) |> repo.update!()
      end

      outcome
    end
  end

  # How much of *this* grant is left, with promotional spending attributed to
  # whichever grant expires soonest.
  #
  # `promotional` on the balance is the sum of every live grant, so expiring
  # one against that total let the first grant to expire take credit a later
  # one had contributed: grant $5 expiring in October and $10 expiring in
  # December, spend $12, and October's expiry reclaimed the $3 that was all
  # December's. Spending soonest-first is both the tenant-friendly order and
  # the one that makes each grant's remainder well defined.
  @spec remaining_on_grant(module(), CreditTransaction.t(), CreditBalance.t()) ::
          non_neg_integer()
  defp remaining_on_grant(repo, grant, _row) do
    from(t in CreditTransaction,
      where:
        t.tenant_key == ^grant.tenant_key and
          (t.amount < 0 or (t.kind == ^:grant and t.category == ^:promotional)),
      # `seq`, not `inserted_at`. The fold this feeds is causal: an `:expire`
      # entry names the grant it consumed and the grant has to have been folded
      # before it. `inserted_at` comes from a wall clock that steps backwards
      # (X59, X100), so a row written second could sort first and the fold
      # raised `KeyError` on it (X213, measured as 43 expiries out of 50 in one
      # run). A Postgres identity is assigned in commit order and cannot.
      order_by: [asc: t.seq]
    )
    |> repo.stream()
    |> Promotions.remaining(grant.id)
  end

  # Whether the allocator owns this wallet. Read from the row the caller just
  # locked `FOR UPDATE`, which is what makes it impossible for the legacy
  # writer and the allocator to run together on one wallet: a cutover has to
  # take the same lock to set it.
  @spec lots?(CreditBalance.t()) :: boolean()
  defp lots?(%CreditBalance{lots_enabled_at: nil}), do: false
  defp lots?(%CreditBalance{}), do: true

  # A partial expiry has to stay repeatable, so it cannot reuse the reference a
  # completed one takes (the unique index on (kind, reference) would refuse the
  # second pass).
  defp expire_reference(grant_id, true), do: "expire:" <> grant_id

  defp expire_reference(grant_id, false),
    do: "expire:" <> grant_id <> ":" <> Integer.to_string(System.unique_integer([:positive]))

  # -- transaction plumbing ---------------------------------------------------

  @spec transact((module() -> outcome())) :: {:ok, CreditTransaction.t()} | {:error, term()}
  defp transact(fun) do
    case transact_outcome(fun) do
      {:ok, outcome} -> {:ok, outcome.txn}
      {:error, reason} -> {:error, reason}
    end
  end

  # Same, but hands back the whole outcome — chiefly so a caller can learn
  # whether an entry was new or a duplicate *from inside the row lock* rather
  # than probing for it beforehand and racing a concurrent delivery.
  @spec transact_outcome((module() -> outcome())) :: {:ok, outcome()} | {:error, term()}
  defp transact_outcome(fun) do
    repo = Config.repo()

    # A refusal returns; it does not roll back.
    #
    # An already-settled hold, a duplicate reference, a balance that cannot
    # cover a debit — these are answers, and every one of them is decided
    # *before* anything is written, so there is nothing to undo. Answering them
    # with `repo.rollback/1` destroyed the caller's transaction as well as this
    # one: `rollback/1` in a nested transaction marks the whole thing for
    # rollback, savepoint or not (it is documented, and Postgres aborts back to
    # the outermost BEGIN). A host that wrapped a ledger call in its own
    # transaction — a settle beside the status flip it arms, say — lost its own
    # writes to a duplicate delivery, and its next statement failed too.
    case repo.transaction(fn -> fun.(repo) end) do
      {:ok, {:refused, reason}} ->
        {:error, reason}

      {:ok, outcome} ->
        emit(outcome)
        {:ok, outcome}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A refusal decided before anything was written. Returned rather than rolled
  # back, so an enclosing transaction of the caller's own survives it.
  @spec refuse(term()) :: {:refused, term()}
  defp refuse(reason), do: {:refused, reason}

  # Ensures the tenant has a balance row and returns it locked for the rest of
  # the transaction. Every write to a tenant's ledger serialises on this lock;
  # holds and debits are checked against the locked row, which is what makes
  # "exactly ten $0.10 holds against $1.00" true under concurrency.
  @spec locked_row(module(), String.t()) :: CreditBalance.t()
  defp locked_row(repo, tenant_key) do
    now = Clock.now()

    repo.insert_all(
      CreditBalance,
      [
        %{
          id: Ecto.UUID.generate(),
          tenant_key: tenant_key,
          currency: Config.credits_currency(),
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:tenant_key]
    )

    repo.one!(from(b in CreditBalance, where: b.tenant_key == ^tenant_key, lock: "FOR UPDATE"))
  end

  # Writes one ledger entry against the locked `row` and moves the row to match.
  @spec apply_entry(module(), CreditBalance.t(), map()) :: outcome()
  defp apply_entry(repo, row, attrs) do
    amount = Map.fetch!(attrs, :amount)
    held_delta = Map.get(attrs, :held_delta, 0)
    balance_after = row.balance + amount
    held_after = row.held + held_delta

    promotional_after =
      row.promotional
      |> promotional_delta(attrs)
      |> min(max(balance_after, 0))
      |> max(0)

    entry =
      Map.merge(attrs, %{
        tenant_key: row.tenant_key,
        held_delta: held_delta,
        balance_after: balance_after,
        held_after: held_after,
        promotional_after: promotional_after,
        inserted_at: Clock.now()
      })

    txn =
      case repo.insert(CreditTransaction.changeset(%CreditTransaction{}, entry)) do
        {:ok, txn} -> txn
        {:error, changeset} -> repo.rollback(changeset)
      end

    updated =
      row
      |> Ecto.Changeset.change(
        balance: balance_after,
        held: held_after,
        promotional: promotional_after
      )
      |> repo.update!()

    %{txn: txn, before: row, after: updated, duplicate: false, overrun: false}
  end

  @spec promotional_delta(non_neg_integer(), map()) :: integer()
  defp promotional_delta(promotional, %{kind: :grant, category: :promotional, amount: amount}),
    do: promotional + amount

  # A reversal takes back one specific paid grant, so it must not eat the
  # promotional figure. Letting it meant refunding a paid top-up quietly
  # consumed the trial grant's remaining value, leaving nothing for the
  # expirer to reclaim and the grant live for ever.
  defp promotional_delta(promotional, %{category: :reversal}), do: promotional

  defp promotional_delta(promotional, %{amount: amount}) when amount < 0,
    do: promotional + amount

  defp promotional_delta(promotional, _attrs), do: promotional

  @spec sufficient?(CreditBalance.t(), integer()) :: boolean()
  defp sufficient?(row, amount),
    do: row.balance - row.held + Config.credits_overdraft_tolerance() >= amount

  @doc """
  What `tenant_key` can spend right now, which is what `sufficient?/2` compares
  against.

  On a legacy wallet it is `balance - held`, exactly as before. On a cut-over
  wallet it is the sum of the **eligible** lots' `available` less `debt`, and
  the two differences are deliberate: credit whose `expires_at` has passed is
  not spendable even though the sweep has not reached it yet, and a wallet that
  owes money cannot spend until the debt is repaid.
  """
  @spec spendable(String.t()) :: integer()
  def spendable(tenant_key) do
    case fetch(tenant_key) do
      nil -> 0
      %CreditBalance{lots_enabled_at: nil} = row -> row.balance - row.held
      %CreditBalance{} = row -> lot_spendable(Config.repo(), row, Clock.db_now())
    end
  end

  # One aggregate rather than the whole book: this runs outside a transaction,
  # it is advisory, and `hold/4` and `debit/5` re-decide it under the row lock
  # from the locked lots.
  @spec lot_spendable(module(), CreditBalance.t(), DateTime.t()) :: integer()
  defp lot_spendable(repo, row, now) do
    # `type(..., :integer)` because `sum()` over a bigint column is `numeric`,
    # which arrives as a Decimal. Micro-dollars are integers everywhere in this
    # package and a Decimal here would be the first place a rounding rule was
    # needed.
    available =
      from(l in CreditLot,
        where:
          l.tenant_key == ^row.tenant_key and l.state == ^:open and
            (is_nil(l.expires_at) or l.expires_at > ^now),
        select: type(coalesce(sum(l.available), 0), :integer)
      )
      |> repo.one()

    available - row.debt
  end

  @spec find(module(), String.t(), CreditTransaction.kind(), String.t()) ::
          CreditTransaction.t() | nil
  defp find(repo, tenant_key, kind, reference) do
    repo.one(
      from(t in CreditTransaction,
        where: t.tenant_key == ^tenant_key and t.kind == ^kind and t.reference == ^reference
      )
    )
  end

  # Locks the hold row so two settles of the same reference serialise and the
  # second sees the first one's status.
  #
  # This lock and the status re-read inside it are what make a hold's terminal
  # transition happen once. Not a timestamp, not a lease and not a duration: the
  # decision "has this already been closed" is answered by a row the caller
  # holds `FOR UPDATE`, so a second caller blocks until the first commits and
  # then reads what it wrote. Two nodes whose clocks disagree by a minute get
  # the same answer as one node.
  #
  # `expected` is the tenant key the caller believes the hold belongs to, or
  # `nil` for "do not check". A mismatch is `{:error, :not_found}` rather than a
  # new error atom: to a caller that named the wrong tenant, this hold does not
  # exist, and the existing return contracts of `settle/3` and `release/1,2` are
  # unchanged. It is checked inside the lock with everything else, so a rename
  # cannot slip between the read and the write.
  @spec pending_hold(module(), String.t(), String.t() | nil) ::
          {:ok, CreditTransaction.t()} | {:error, :not_found | :already_settled}
  defp pending_hold(repo, reference, expected) do
    query =
      from(t in CreditTransaction,
        where: t.kind == ^:hold and t.reference == ^reference,
        lock: "FOR UPDATE"
      )

    case repo.one(query) do
      nil ->
        {:error, :not_found}

      %CreditTransaction{tenant_key: key} when is_binary(expected) and key != expected ->
        {:error, :not_found}

      %CreditTransaction{status: :pending} = hold ->
        {:ok, hold}

      %CreditTransaction{} ->
        {:error, :already_settled}
    end
  end

  # `updated_at` is stamped by the database rather than by this node. The
  # column exists because a hold row is mutated in place and nothing recorded
  # when (finding L9); stamping it from `Clock.now/0` would have put a
  # node clock on a financial row again, which is exactly X181.
  # The tenant a hold belongs to, read without a lock, purely so the balance
  # row can be locked first. A committed row's `tenant_key` is never updated by
  # any path, so there is nothing for a concurrent writer to change under this
  # read, and the hold's status, which is the only thing a decision is made
  # from, is re-read under both locks by `pending_hold/3` immediately after.
  @spec hold_tenant(module(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :not_found}
  defp hold_tenant(repo, reference, expected) do
    query =
      from(t in CreditTransaction,
        where: t.kind == ^:hold and t.reference == ^reference,
        select: t.tenant_key
      )

    case repo.one(query) do
      nil -> {:error, :not_found}
      key when is_binary(expected) and key != expected -> {:error, :not_found}
      key -> {:ok, key}
    end
  end

  @spec close_hold!(module(), CreditTransaction.t(), keyword()) :: CreditTransaction.t()
  defp close_hold!(repo, hold, changes) do
    {1, _} =
      repo.update_all(
        from(t in CreditTransaction,
          where: t.id == ^hold.id,
          update: [set: [updated_at: fragment("(clock_timestamp() AT TIME ZONE 'UTC')")]]
        ),
        set: changes
      )

    struct!(hold, changes)
  end

  # A unique-index violation on the reference (a duplicate from another tenant,
  # which the in-transaction lookup cannot see) is the same error to the caller;
  # it is the only changeset error a hold or debit can produce.
  @spec duplicate_reference_error({:ok, CreditTransaction.t()} | {:error, term()}) ::
          {:ok, CreditTransaction.t()} | {:error, term()}
  defp duplicate_reference_error({:error, %Ecto.Changeset{}}), do: {:error, :duplicate_reference}
  defp duplicate_reference_error(result), do: result

  # -- the lot path -----------------------------------------------------------

  # `Clock.db_now/0` and not `Clock.now/0`. The eligibility decision compares
  # `now` against a lot's `expires_at`, which is a persisted timestamp, and
  # `architecture-map.md` section 3 is binding: both sides of a time comparison
  # come from the same clock, and for anything persisted that clock is the
  # database's. The duration involved is minutes to months, which X100's 439 ms
  # backwards step cannot invert. One read per ledger operation serves the
  # eligibility instant, `granted_at` and the allocation stamps, so there is one
  # instant in the transaction rather than three.
  @spec lot_instant() :: DateTime.t()
  defp lot_instant, do: Clock.db_now()

  # Extracted so the dispatch is one decision in a function of its own rather
  # than a third level of nesting inside the transaction body.
  defp write_grant(repo, row, amount, category, opts) do
    attrs = %{
      kind: :grant,
      amount: amount,
      category: category,
      reference: Keyword.fetch!(opts, :reference),
      expires_at: Keyword.get(opts, :expires_at),
      metadata: Map.new(Keyword.get(opts, :metadata, %{}))
    }

    if lots?(row) do
      grant_with_lots(repo, row, attrs, Keyword.get(opts, :source, %{}))
    else
      apply_entry(repo, row, attrs)
    end
  end

  defp settle_entry(repo, row, hold, actual, reference, metadata) do
    if lots?(row) do
      settle_with_lots(repo, row, hold, actual, reference, metadata)
    else
      apply_entry(repo, row, %{
        kind: :settle,
        amount: -actual,
        held_delta: -hold.held_delta,
        reference: reference,
        hold_transaction_id: hold.id,
        settled_amount: actual,
        metadata: metadata
      })
    end
  end

  defp release_entry(repo, row, hold, reference) do
    if lots?(row) do
      release_with_lots(repo, row, hold, reference)
    else
      apply_entry(repo, row, %{
        kind: :release,
        amount: 0,
        held_delta: -hold.held_delta,
        reference: reference,
        hold_transaction_id: hold.id
      })
    end
  end

  defp grant_with_lots(repo, row, attrs, source) do
    now = lot_instant()
    book = Allocator.book(repo, row.tenant_key)

    lot = %{
      id: Ecto.UUID.generate(),
      tenant_key: row.tenant_key,
      category: attrs.category,
      amount: attrs.amount,
      reference: attrs.reference,
      expires_at: attrs.expires_at,
      granted_at: now,
      # Provisional, and the database assigns the real one on insert. The plan
      # does not depend on it: a grant's only movement is on the new lot
      # itself, so no ordering decision is taken from this number.
      seq: (book |> Enum.map(& &1.seq) |> Enum.max(fn -> 0 end)) + 1,
      source: stringify_source(source)
    }

    # A grant cannot be refused by the planner: it adds value, and the only
    # decision it takes is how much of the new lot the outstanding debt
    # swallows before any of it becomes spendable.
    {:ok, plan} = Allocator.plan(book, {:grant, lot, row.debt})
    write_lot_entry(repo, row, book, attrs, plan, now, :grant)
  end

  defp hold_with_lots(repo, row, amount, reference, metadata) do
    now = lot_instant()
    book = Allocator.book(repo, row.tenant_key)

    case Allocator.plan(book, {:hold, amount, now, row.debt}) do
      {:error, reason} ->
        refuse(reason)

      {:ok, plan} ->
        write_lot_entry(
          repo,
          row,
          book,
          %{kind: :hold, reference: reference, status: :pending, metadata: metadata},
          plan,
          now,
          :hold
        )
    end
  end

  defp debit_with_lots(repo, row, amount, reference, metadata, category, opts) do
    now = lot_instant()
    book = Allocator.book(repo, row.tenant_key)
    allow_negative? = Keyword.fetch!(opts, :allow_negative)

    request =
      {:debit, amount, now, allow_negative?, Config.credits_overdraft_tolerance(), row.debt}

    case Allocator.plan(book, request) do
      {:error, reason} ->
        refuse(reason)

      {:ok, plan} ->
        write_lot_entry(
          repo,
          row,
          book,
          %{kind: :debit, category: category, reference: reference, metadata: metadata},
          plan,
          now,
          :debit
        )
    end
  end

  defp settle_with_lots(repo, row, hold, actual, reference, metadata) do
    now = lot_instant()
    book = Allocator.book(repo, row.tenant_key)
    reservations = Allocator.reservations(repo, hold.id)

    {:ok, plan} = Allocator.plan(book, {:settle, reservations, actual, now, row.debt})

    write_lot_entry(
      repo,
      row,
      book,
      %{
        kind: :settle,
        reference: reference,
        settled_amount: actual,
        hold_transaction_id: hold.id,
        metadata: Map.merge(metadata, written_off(plan))
      },
      plan,
      now,
      :settle
    )
  end

  defp release_with_lots(repo, row, hold, reference) do
    now = lot_instant()
    book = Allocator.book(repo, row.tenant_key)
    reservations = Allocator.reservations(repo, hold.id)

    {:ok, plan} = Allocator.plan(book, {:release, reservations, now, row.debt})

    write_lot_entry(
      repo,
      row,
      book,
      %{
        kind: :release,
        reference: reference,
        hold_transaction_id: hold.id,
        metadata: written_off(plan)
      },
      plan,
      now,
      :release
    )
  end

  # Value a hold was still holding on a lot that had passed its expiry. It is
  # written off rather than handed back (I12, finding L1), and because that is
  # the one case where a settle or a release moves the balance by something
  # other than its own cost, the amount is recorded on the row that did it.
  defp written_off(plan) do
    case Enum.filter(plan.movements, &(&1.from == :reserved and &1.to == :expired)) do
      [] -> %{}
      moves -> %{"expired_amount" => moves |> Enum.map(& &1.amount) |> Enum.sum()}
    end
  end

  # Writes the ledger row, then hands the plan to the applier.
  #
  # `amount` and `held_delta` are **computed from the projection**, never passed
  # in: the log's own law is that the balance is the sum of every amount, and
  # the one way to keep that true through a write-off is to make the row's
  # amount the balance delta it really caused. `settled_amount` carries the
  # cost, which is what a settle above or below its hold is about.
  defp write_lot_entry(repo, row, book, attrs, plan, now, operation) do
    debt_after = row.debt + plan.debt_delta
    deltas = Allocator.deltas(book, plan, row.debt, debt_after)

    entry =
      Map.merge(attrs, %{
        tenant_key: row.tenant_key,
        amount: deltas.balance,
        held_delta: deltas.held,
        balance_after: row.balance + deltas.balance,
        held_after: row.held + deltas.held,
        promotional_after: row.promotional + deltas.promotional
      })

    txn =
      case repo.insert(CreditTransaction.changeset(%CreditTransaction{}, entry)) do
        {:ok, txn} -> txn
        {:error, changeset} -> repo.rollback(changeset)
      end

    applied = %{plan: plan, deltas: deltas, debt_after: debt_after}
    updated = Allocator.apply_plan(repo, row, txn, applied, now, operation)
    %{txn: txn, before: row, after: updated, duplicate: false, overrun: false}
  end

  defp stringify_source(source) when is_map(source) do
    Map.new(source, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  @doc """
  Hands `tenant_key`'s wallet to the allocator.

  **Only safe on a wallet with no ledger history**, which is all this unit
  needs and all it permits: a wallet with rows in it has to have those rows
  replayed into lots first, and that replay, its per-wallet reconciliation
  report and the refusal to cut over an ambiguous wallet are
  `mix aurora_meter.credits.migrate_lots` (build unit 06b). This raises rather
  than cutting over a wallet it cannot vouch for.

  The flag is set under the balance row's own `FOR UPDATE` lock, which is what
  makes it impossible for the legacy writer and the allocator to run together
  on one wallet.
  """
  @spec enable_lots!(String.t()) :: CreditBalance.t()
  def enable_lots!(tenant_key) do
    repo = Config.repo()

    {:ok, row} =
      repo.transaction(fn ->
        row = locked_row(repo, tenant_key)

        existing =
          repo.one(
            from(t in CreditTransaction,
              where: t.tenant_key == ^tenant_key,
              select: count(t.id)
            )
          )

        if existing > 0 do
          raise ArgumentError,
                "AuroraMeter.Credits.Ledger.enable_lots!/1 refuses #{inspect(tenant_key)}: it " <>
                  "has #{existing} ledger rows and no replay has been run for it. Cutting a " <>
                  "wallet over means replaying its history into lots and reconciling the " <>
                  "result, which is `mix aurora_meter.credits.migrate_lots` (build unit 06b)."
        end

        row
        |> Ecto.Changeset.change(lots_enabled_at: DateTime.truncate(Clock.db_now(), :second))
        |> repo.update!()
      end)

    row
  end

  # -- post-commit side effects -----------------------------------------------

  @spec emit(outcome()) :: :ok
  defp emit(%{txn: txn, before: before, after: after_row} = outcome) do
    available_before = before.balance - before.held
    available_after = after_row.balance - after_row.held

    :telemetry.execute(
      [:aurora_meter, :credits, txn.kind],
      %{
        amount: if(outcome.duplicate, do: 0, else: txn.amount),
        balance_after: after_row.balance,
        available_after: available_after
      },
      %{
        tenant_key: txn.tenant_key,
        reference: txn.reference,
        category: txn.category,
        duplicate: outcome.duplicate,
        overrun: outcome.overrun
      }
    )

    unless outcome.duplicate do
      PubSub.broadcast(
        Config.pubsub(),
        topic(txn.tenant_key),
        {:aurora_meter, :credits,
         %{
           tenant_key: txn.tenant_key,
           balance: after_row.balance,
           held: after_row.held,
           available: available_after
         }}
      )
    end

    maybe_low_balance(after_row, available_before, available_after)
  end

  # Fires once per crossing: only when the available balance was at or above
  # the threshold before this entry and below it after, so a tenant sitting
  # under the line does not get an alert on every debit.
  @spec maybe_low_balance(CreditBalance.t(), integer(), integer()) :: :ok
  defp maybe_low_balance(row, available_before, available_after) do
    threshold = row.low_balance_threshold || Config.credits_low_balance_threshold()

    if threshold && available_before >= threshold && available_after < threshold do
      event = %{tenant_key: row.tenant_key, available: available_after, threshold: threshold}

      :telemetry.execute(
        [:aurora_meter, :credits, :low_balance],
        %{available: available_after, threshold: threshold},
        %{tenant_key: row.tenant_key}
      )

      PubSub.broadcast(
        Config.pubsub(),
        topic(row.tenant_key),
        {:aurora_meter, :low_balance, event}
      )

      case Config.credits_low_balance_handler() do
        nil -> :ok
        handler when is_function(handler, 1) -> handler.(event)
      end
    end

    :ok
  end
end
