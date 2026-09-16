defmodule AuroraMeter.Credits.Ledger do
  @moduledoc false
  # Transactional core of `AuroraMeter.Credits`. Every public function here runs
  # one database transaction and, only after it commits, the side effects
  # (telemetry, PubSub, the low-balance hook), so a handler never observes a
  # balance that later rolled back.
  #
  # "After it commits" means after the **outermost** transaction commits. A
  # ledger call made inside a host's own transaction opens a savepoint, not a
  # transaction, so its return says nothing about durability; those effects are
  # queued on the calling process and run by
  # `AuroraMeter.Credits.after_commit/1` (finding L18).
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
  alias AuroraMeter.Credits.Money
  alias AuroraMeter.Credits.Promotions
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Schema.CreditRecurrence
  alias AuroraMeter.Schema.CreditTransaction
  alias Phoenix.PubSub

  @typedoc "What one page of the expiry sweep examined. Documented on `AuroraMeter.Credits`."
  @type expiry_report :: AuroraMeter.Credits.expiry_report()

  @typep outcome :: %{
           required(:txn) => CreditTransaction.t(),
           required(:before) => CreditBalance.t(),
           required(:after) => CreditBalance.t(),
           required(:duplicate) => boolean(),
           required(:overrun) => boolean(),
           required(:spendable_after) => integer(),
           # Added by `settle_outcome/2` inside the transaction and by
           # `transact_outcome/1` after it, in that order, so the map a builder
           # returns carries neither yet.
           optional(:crossing) => {:alert, map()} | :none,
           optional(:deferred) => boolean()
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
          {:ok, CreditTransaction.t()} | {:error, :duplicate_reference | Ecto.Changeset.t()}
  def grant(tenant_key, amount, opts) do
    case grant_with_status(tenant_key, amount, opts) do
      {:ok, txn, _status} -> {:ok, txn}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec grant_with_status(String.t(), pos_integer(), keyword()) ::
          {:ok, CreditTransaction.t(), :new | :duplicate}
          | {:error, :duplicate_reference | Ecto.Changeset.t()}
  def grant_with_status(tenant_key, amount, opts) do
    reference = Keyword.fetch!(opts, :reference)
    category = Keyword.get(opts, :category, :paid)

    transact_outcome(fn repo ->
      row = locked_row(repo, tenant_key)

      case find(repo, tenant_key, :grant, reference) do
        %CreditTransaction{} = existing ->
          duplicate_outcome(repo, row, existing)

        nil ->
          write_grant(repo, row, amount, category, opts)
      end
    end)
    |> case do
      {:ok, %{txn: txn, duplicate: true}} -> {:ok, txn, :duplicate}
      {:ok, %{txn: txn}} -> {:ok, txn, :new}
      {:error, reason} -> {:error, grant_error(reason)}
    end
  end

  # **Only a reference collision becomes an atom; every other changeset stays a
  # changeset** (finding L3). The in-transaction lookup above is scoped to this
  # tenant, so a reference another tenant already used is invisible to it and
  # the insert hits the global unique index on `(kind, reference)`. `hold/4` and
  # `debit/4` have always answered that with `:duplicate_reference`; `grant/3`
  # answered with a raw `%Ecto.Changeset{}`, which is a different shape for the
  # same fact and is what a webhook handler then had to special case.
  #
  # The narrow test is deliberate. Mapping *every* changeset error the way
  # `duplicate_reference_error/1` does would hide the one changeset a grant can
  # genuinely produce for another reason: `validate_expiry/1` refuses an
  # `:expires_at` on a non-promotional grant, and a caller needs to see that
  # field and that message, not `:duplicate_reference`.
  @spec grant_error(term()) :: term()
  defp grant_error(%Ecto.Changeset{} = changeset) do
    if duplicate_reference?(changeset), do: :duplicate_reference, else: changeset
  end

  defp grant_error(reason), do: reason

  @spec duplicate_reference?(Ecto.Changeset.t()) :: boolean()
  defp duplicate_reference?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:reference, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _other -> false
    end)
  end

  @spec hold(String.t(), pos_integer(), String.t(), keyword()) ::
          {:ok, CreditTransaction.t()}
          | {:error, :insufficient_credits | :debt_outstanding | :duplicate_reference}
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
          {:ok, CreditTransaction.t()}
          | {:error, :insufficient_credits | :debt_outstanding | :duplicate_reference}
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
          debit_with_lots(
            repo,
            row,
            amount,
            reference,
            Map.new(metadata),
            category,
            allow_negative?
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

  @doc """
  Takes `amount` back for money that has already left the payment provider.

  Writes `kind: :reverse, category: :reversal` and is never refused for want of
  balance. Two things follow from the kind, and both are the point of build unit
  06c:

    * the reference namespace is `:reverse`, so a host debit and a Pro reversal
      that happen to share one reference string no longer collide and neither is
      told `:duplicate_reference` for the other's write (finding L2). The unique
      index is on `(kind, reference)`, so the separation is the database's, not
      a convention.
    * every reader that used to recognise a reversal by `category` still does,
      because `category: :reversal` is kept. `Schema.CreditTransaction.reversal?/1`
      is the single predicate that knows both shapes.

  ## On a cut-over wallet (repair unit R1)

  It takes the credit back off the wallet's **non-promotional** lots, in spend
  order, draining `available`, then `consumed`, then `reserved`, and writing
  `reversed`. That is `reverse_lot/5`'s arithmetic with the payment filter
  removed, not a second model: see `Allocator.plan/2`'s `{:reverse, :wallet,
  ...}`.

  Whatever those lots cannot give back becomes `debt`, so the call is still
  never refused and the balance still falls by the full amount.
  """
  @spec reverse(String.t(), pos_integer(), String.t(), map(), keyword()) ::
          {:ok, CreditTransaction.t()} | {:error, :duplicate_reference}
  def reverse(tenant_key, amount, reference, metadata, opts \\ []) do
    _ = opts

    transact(fn repo ->
      row = locked_row(repo, tenant_key)

      cond do
        find(repo, tenant_key, :reverse, reference) ->
          refuse(:duplicate_reference)

        lots?(row) ->
          reverse_with_lots(repo, row, amount, reference, Map.new(metadata))

        true ->
          apply_entry(repo, row, %{
            kind: :reverse,
            category: :reversal,
            amount: -amount,
            reference: reference,
            metadata: Map.new(metadata)
          })
      end
    end)
    |> duplicate_reference_error()
  end

  @doc """
  Takes `amount` back off the lots one payment funded.

  The source-scoped sibling of `reverse/5`. Build unit 06e, and the function
  whose existence opens `AuroraMeter.Credits.LotMigration`'s cutover gate.
  """
  @spec reverse_lot(String.t(), pos_integer(), String.t(), String.t(), keyword()) ::
          {:ok, CreditTransaction.t()}
          | {:error, :duplicate_reference | :no_matching_lots | :exceeds_source}
  def reverse_lot(tenant_key, amount, reference, payment_intent_id, opts) do
    partial? = Keyword.get(opts, :allow_partial, false)
    metadata = Map.new(Keyword.get(opts, :metadata, %{}))

    transact(fn repo ->
      row = locked_row(repo, tenant_key)

      cond do
        find(repo, tenant_key, :reverse, reference) ->
          refuse(:duplicate_reference)

        # A wallet the allocator does not own has no lots at all, so there is
        # nothing scoped to reverse against. The caller falls back to the
        # wallet-wide `reverse/5`, which is what the money needs and what
        # 06e's legacy-fallback path does.
        not lots?(row) ->
          refuse(:no_matching_lots)

        true ->
          reverse_lot_locked(repo, row, amount, reference, payment_intent_id, metadata, partial?)
      end
    end)
    |> duplicate_reference_error()
  end

  defp reverse_lot_locked(repo, row, amount, reference, intent_id, metadata, partial?) do
    now = lot_instant()
    book = Allocator.book(repo, row.tenant_key)

    case Allocator.plan(book, {:reverse, intent_id, amount, now, row.debt}) do
      {:error, :no_matching_lot} ->
        refuse(:no_matching_lots)

      {:ok, plan} ->
        # **Counted from the movements, not taken from the planner's word for
        # it.** `to: :reversed` is the only thing that is the reversal; the
        # plan also carries the `consume` movements that repay the debt the
        # reversal created (X262), and counting those would report a shortfall
        # as met.
        taken = moved_to(plan, :reversed)
        shortfall = amount - taken

        cond do
          taken == 0 ->
            refuse(:exceeds_source)

          shortfall > 0 and not partial? ->
            refuse(:exceeds_source)

          true ->
            write_lot_entry(
              repo,
              row,
              book,
              %{
                kind: :reverse,
                category: :reversal,
                reference: reference,
                metadata: shortfall_metadata(metadata, shortfall)
              },
              plan,
              now,
              :reverse
            )
        end
    end
  end

  @doc """
  Puts `amount` back onto the lots one payment funded, out of what an earlier
  reversal took. Build unit 06e.
  """
  @spec restore_lot(String.t(), pos_integer(), String.t(), String.t(), keyword()) ::
          {:ok, CreditTransaction.t()}
          | {:error, :duplicate_reference | :no_matching_lots | :exceeds_reversed}
  def restore_lot(tenant_key, amount, reference, payment_intent_id, opts) do
    partial? = Keyword.get(opts, :allow_partial, false)
    metadata = Map.new(Keyword.get(opts, :metadata, %{}))

    transact(fn repo ->
      row = locked_row(repo, tenant_key)

      cond do
        find(repo, tenant_key, :grant, reference) ->
          refuse(:duplicate_reference)

        not lots?(row) ->
          refuse(:no_matching_lots)

        true ->
          restore_lot_locked(repo, row, amount, reference, payment_intent_id, metadata, partial?)
      end
    end)
    |> duplicate_reference_error()
  end

  defp restore_lot_locked(repo, row, amount, reference, intent_id, metadata, partial?) do
    now = lot_instant()
    book = Allocator.book(repo, row.tenant_key)

    case Allocator.plan(book, {:restore, intent_id, amount, now, row.debt}) do
      {:error, :no_matching_lot} ->
        refuse(:no_matching_lots)

      {:ok, plan} ->
        given_back = moved_to(plan, :available)
        shortfall = amount - given_back

        cond do
          given_back == 0 ->
            refuse(:exceeds_reversed)

          shortfall > 0 and not partial? ->
            refuse(:exceeds_reversed)

          true ->
            write_lot_entry(
              repo,
              row,
              book,
              %{
                kind: :grant,
                category: :adjustment,
                reference: reference,
                metadata: shortfall_metadata(metadata, shortfall)
              },
              plan,
              now,
              :restore
            )
        end
    end
  end

  # `:reverse` and `:restore` are the only two kinds that name their bucket,
  # which is what makes this readable from the movements rather than from a
  # field the planner would have to be trusted for.
  defp moved_to(plan, bucket) do
    kind = if bucket == :reversed, do: :reverse, else: :restore

    plan.movements
    |> Enum.filter(&(&1.to == bucket and &1.kind == kind))
    |> Enum.reduce(0, &(&1.amount + &2))
  end

  defp shortfall_metadata(metadata, 0), do: metadata

  defp shortfall_metadata(metadata, shortfall),
    do: Map.put(metadata, "shortfall", shortfall)

  @spec set_low_balance_threshold(String.t(), integer() | nil) :: {:ok, CreditBalance.t()}
  def set_low_balance_threshold(tenant_key, threshold) do
    repo = Config.repo()

    repo.transaction(fn ->
      row = locked_row(repo, tenant_key)

      updated =
        row
        |> CreditBalance.changeset(%{low_balance_threshold: threshold})
        |> repo.update!()

      restate_crossing(repo, updated, threshold)
    end)
  end

  # **A standing crossing is state, and moving the threshold changes what that
  # state means.** Lower a threshold below where the wallet already sits and the
  # wallet is no longer low; leave the flag set and the next genuine fall below
  # the new line would find it already set and alert nobody. So the flag is
  # recomputed here, under the same row lock every other decision about it is
  # taken under.
  #
  # It only ever **clears**. Raising a threshold above a wallet's current
  # spendable does not alert, deliberately: an alert says "this wallet has just
  # crossed", and nothing about the wallet moved. The next write that leaves it
  # below the new line finds no standing flag and alerts then.
  @spec restate_crossing(module(), CreditBalance.t(), integer() | nil) :: CreditBalance.t()
  defp restate_crossing(_repo, %CreditBalance{low_balance_crossing_id: nil} = row, _threshold),
    do: row

  defp restate_crossing(repo, row, threshold) do
    effective = threshold || Config.credits_low_balance_threshold()

    if is_nil(effective) or spendable_of(repo, row) >= effective do
      write_crossing(repo, row, nil)
      %{row | low_balance_crossing_id: nil}
    else
      row
    end
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
    # **Whether the side effects may run is decided here, before the work, and
    # it is decided by whether the caller already had a transaction open**
    # (finding L18). Inside one, `repo.transaction/1` opens a savepoint, and
    # what its return means is "the savepoint was released", not "this is
    # durable": the host can still roll the whole thing back. Telemetry, PubSub
    # and the low-balance handler all describe money, and a handler that fires
    # for a balance no reader will ever find is worse than one that fires late,
    # so they are queued and `AuroraMeter.Credits.after_commit/1` runs them.
    nested? = repo.in_transaction?()

    case repo.transaction(fn -> settle_outcome(repo, fun.(repo)) end) do
      {:ok, {:refused, reason}} ->
        {:error, reason}

      {:ok, outcome} ->
        outcome = Map.put(outcome, :deferred, nested?)
        if nested?, do: defer(outcome), else: emit(outcome)
        {:ok, outcome}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Everything that must happen inside the ledger's own transaction after the
  # entry is written: today, exactly the low-balance crossing decision. It is
  # here rather than after the commit because the flag is the thing that makes
  # one crossing produce one alert, and a flag written outside the transaction
  # that moved the balance could survive a rollback of that balance.
  @spec settle_outcome(module(), outcome() | {:refused, term()}) ::
          outcome() | {:refused, term()}
  defp settle_outcome(_repo, {:refused, _reason} = refusal), do: refusal

  defp settle_outcome(repo, outcome),
    do: Map.put(outcome, :crossing, decide_crossing(repo, outcome))

  # A refusal decided before anything was written. Returned rather than rolled
  # back, so an enclosing transaction of the caller's own survives it.
  @spec refuse(term()) :: {:refused, term()}
  defp refuse(reason), do: {:refused, reason}

  # Ensures the tenant has a balance row and returns it locked for the rest of
  # the transaction. Every write to a tenant's ledger serialises on this lock;
  # holds and debits are checked against the locked row, which is what makes
  # "exactly ten $0.10 holds against $1.00" true under concurrency.
  #
  # **A wallet created from here is born on the allocator** (`lots_enabled_at`
  # stamped at the same instant as `inserted_at`), and that is an orchestrator
  # decision of 2026-09-17 on findings X380, X283 and X255 rather than a
  # convenience. It is worth saying why it is *this* line and not another one,
  # because two units before this declined to write it and were right to.
  #
  # 06b's criterion asked `locked_row/2` to stamp the flag "when the INSERT
  # actually inserts". 06b, 06e and repair unit R1 all refused, for one reason
  # (X255, X283): `architecture-map.md` 7.4 makes `lots_enabled_at` the output
  # of a **verified replay**, paired with a per-wallet checkpoint report, so a
  # flag stamped here would mint cut-over wallets with no report and no
  # operator decision, on `mix deps.update` rather than on a choice.
  #
  # **That objection is entirely about wallets that already exist**, and this
  # line cannot reach one. `on_conflict: :nothing` on `conflict_target:
  # [:tenant_key]` means the statement either inserts a wallet that did not
  # exist a moment ago or writes nothing at all: there is no path by which it
  # updates a row, so no wallet with a history to replay is moved, and 7.4's
  # requirement is untouched for every wallet 7.4 is about. A new wallet has no
  # history to reconcile, so the replay it would be asked for is vacuous, which
  # is the observation R2 made and X255's original requirement stated outright:
  # "a genuinely new wallet is born on the lot path".
  #
  # The split population this creates (wallets from before the upgrade on the
  # legacy writer, wallets from after it on the allocator) is the state
  # `mix aurora_meter.credits.migrate_lots` exists to resolve. It is documented
  # in `docs/upgrading-to-lots.md` and `docs/credits.md` rather than left for a
  # host to find by watching two wallets behave differently.
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
          lots_enabled_at: DateTime.truncate(now, :second),
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

    %{
      txn: txn,
      before: row,
      after: updated,
      duplicate: false,
      overrun: false,
      # Derived, not queried. On a legacy wallet spendable *is* `balance -
      # held`, and both halves were just computed under the row lock, so
      # re-reading them would be a round trip that could only agree.
      spendable_after: balance_after - held_after
    }
  end

  # A second delivery of one payment: nothing moved. The outcome still carries a
  # spendable figure, because telemetry reports one on every entry, and it is
  # the only place that has to be read rather than derived. No crossing is
  # evaluated from it at all (`decide_crossing/2` refuses a duplicate outright),
  # which is the replay half of task 06.07: a redelivered webhook that produces
  # no balance change cannot produce a second alert.
  @spec duplicate_outcome(module(), CreditBalance.t(), CreditTransaction.t()) :: outcome()
  defp duplicate_outcome(repo, row, existing) do
    %{
      txn: existing,
      before: row,
      after: row,
      duplicate: true,
      overrun: false,
      spendable_after: spendable_of(repo, row)
    }
  end

  @spec spendable_of(module(), CreditBalance.t()) :: integer()
  defp spendable_of(_repo, %CreditBalance{lots_enabled_at: nil} = row),
    do: row.balance - row.held

  defp spendable_of(repo, %CreditBalance{} = row), do: lot_spendable(repo, row, lot_instant())

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

  It goes through `Allocator.spendable_figure/2`, which is the planner's own
  `debt > 0` refusal expressed as a number, so this figure and
  `AuroraMeter.Credits.sufficient?/2` built on it cannot say a wallet may spend
  something `hold/4` would refuse (repair unit R3, findings X357 and X361).
  """
  @spec spendable(String.t()) :: integer()
  def spendable(tenant_key) do
    case fetch(tenant_key) do
      nil -> 0
      %CreditBalance{lots_enabled_at: nil} = row -> row.balance - row.held
      %CreditBalance{} = row -> lot_spendable(Config.repo(), row, Clock.db_now())
    end
  end

  @doc """
  The two spendable figures `AuroraMeter.Credits.balance/1` reports beside the
  stored ones, in one read.

  On a legacy wallet they are the stored figures and **no query is issued at
  all**: spendable is `balance - held` by definition there, and promotional
  spendable is the `promotional` column. On a cut-over wallet both come from one
  aggregate over the wallet's eligible lots, so `balance/1` costs one extra
  round trip for a wallet that has lots and none for a wallet that has not.

  **Both figures answer the same question about the same planner: what a new
  hold or debit would be allowed to take.** While `debt > 0` the answer is
  nothing, because the `{:hold, ...}` and `{:debit, ...}` clauses refuse with
  `:debt_outstanding` before they look at a lot, so both figures report that
  and neither can be positive (repair unit R3, findings X357 and X361). They
  come through `Allocator.spendable_figure/2` and
  `Allocator.promotional_spendable_figure/2`, which are that refusal written as
  a number and are the only implementation of it.

  Until repair unit R2 the question could not arise: every incoming value
  repaid debt out of eligible availability of any category, so an outstanding
  debt implied no availability at all. R2 stops a debt being repaid out of
  credit the wallet already holds when that credit is promotional (finding
  X355), which is what `architecture-map.md` 7.2's promotional rule costs, and
  it made this state ordinary. Between R2 and R3 a refunded wallet reported
  `promotional_spendable: 4_000_000` and could spend none of it.

  **What the wallet holds is a different question and is reported elsewhere,
  unchanged.** `promotional` on the balance row is the promotional credit the
  wallet still has and has not spent or let expire, and a promotion standing
  beside a debt survives whole; `debt` says why none of it is spendable, and a
  grant of any kind clears it. LI-06a-5 as amended: `debt > 0` implies no
  **non-promotional** eligible availability.
  """
  @spec figures(CreditBalance.t()) :: %{
          spendable: integer(),
          promotional_spendable: non_neg_integer()
        }
  def figures(%CreditBalance{lots_enabled_at: nil} = row),
    do: %{spendable: row.balance - row.held, promotional_spendable: row.promotional}

  def figures(%CreditBalance{} = row) do
    %{rows: [[available, promotional]]} =
      Config.repo().query!(
        """
        SELECT coalesce(sum(available), 0)::bigint,
               coalesce(sum(available) FILTER (WHERE category = 'promotional'), 0)::bigint
          FROM aurora_meter_credit_lots
         WHERE tenant_key = $1
           AND state = 'open'
           AND (expires_at IS NULL OR expires_at > $2)
        """,
        [row.tenant_key, DateTime.truncate(Clock.db_now(), :second)]
      )

    %{
      spendable: Allocator.spendable_figure(available, row.debt),
      promotional_spendable: Allocator.promotional_spendable_figure(promotional, row.debt)
    }
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

    Allocator.spendable_figure(available, row.debt)
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

  # A debit on a cut-over wallet: eligible lots in spend order, promotional
  # first, which is what a spend is.
  #
  # **It plans a debit and it can no longer be handed anything else**
  # (repair unit R1). Until R1 this function took `kind` and `category` as
  # arguments and built a `{:debit, ...}` request whatever it had been handed,
  # and `reverse/5` handed it `:reverse`. So a refund on a cut-over wallet was
  # planned as a spend: it consumed promotional lots first and wrote nothing
  # into `reversed` (finding X250). The kind is fixed here rather than passed,
  # so the same mistake cannot be made again by a fourth caller.
  defp debit_with_lots(repo, row, amount, reference, metadata, category, allow_negative?) do
    now = lot_instant()
    book = Allocator.book(repo, row.tenant_key)

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

  # The **wallet-wide** reversal on a cut-over wallet, and the sibling of
  # `reverse_lot_locked/7` rather than a second model of what a refund is.
  #
  # It makes the same planner request with the same bucket order (`available`,
  # then `consumed`, then `reserved`), the same exclusion of promotional lots
  # and the same repayment of the debt it creates. One thing differs, and it is
  # the target set: with no payment to scope by, every non-promotional lot in
  # the wallet is a target, in spend order. `Allocator.plan/2`'s `{:reverse,
  # :wallet, ...}` is where that is written down.
  #
  # It is never refused, which is `reverse/5`'s whole contract: the money has
  # already left the payment provider, so what the wallet's paid lots cannot
  # give back is recorded as `debt`, and `debt` is what a negative balance is
  # made of on a lot wallet. A wallet holding nothing but promotional credit
  # therefore takes the entire reversal as debt and keeps the promotion.
  defp reverse_with_lots(repo, row, amount, reference, metadata) do
    now = lot_instant()
    book = Allocator.book(repo, row.tenant_key)

    {:ok, plan} = Allocator.plan(book, {:reverse, :wallet, amount, now, row.debt})

    write_lot_entry(
      repo,
      row,
      book,
      %{kind: :reverse, category: :reversal, reference: reference, metadata: metadata},
      plan,
      now,
      :reverse
    )
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

    %{
      txn: txn,
      before: row,
      after: updated,
      duplicate: false,
      overrun: false,
      # `plan.book` is the book *after* the movements, and it includes a new
      # grant's lot, so the planner already holds everything the figure needs.
      # Asking the database again would be a second round trip inside the row
      # lock for an answer the plan cannot disagree with.
      spendable_after: Allocator.spendable(plan.book, debt_after, now)
    }
  end

  defp stringify_source(source) when is_map(source) do
    Map.new(source, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  # -- recurring grants (build unit 06d) --------------------------------------

  @typedoc false
  @type recurrence_request :: %{
          key: String.t(),
          reference: String.t(),
          policy: map(),
          policy_json: map(),
          period: %{start: DateTime.t(), end: DateTime.t()},
          historical?: boolean(),
          previous: %{id: Ecto.UUID.t(), key: String.t(), rollover: non_neg_integer()} | nil,
          source: map(),
          metadata: map(),
          gate: (module() -> :ok | {:skip, atom()})
        }

  @doc false
  # One period of one recurring allowance, in one transaction.
  #
  # Everything a period does is here rather than in `Credits.Recurrences`
  # because everything a period does is a ledger write, and the lock order
  # (`architecture-map.md` 7.3: balance row, then transaction rows, then lots
  # `ORDER BY id`) is this module's to keep. The engine decides *which* periods
  # and *what* policy; this decides nothing except how to write it.
  #
  # Two clocks, and the split is the contract in `architecture-map.md` 3. The
  # engine passes no instant: the period bounds it chose came from `Clock.now/0`
  # (the question "what period is it" is a wall-clock question). Every decision
  # taken here compares against a column this database stamped, so it takes
  # `Clock.db_now/0`, which is what `lot_instant/0` already is.
  #
  # The ledger rows it can write, in order:
  #
  #   1. the previous period's lots expire (so the value about to be carried
  #      cannot also stay spendable);
  #   2. the period's allowance is granted;
  #   3. the carried remainder is granted as a lot of its own;
  #   4. for a historical period, both of those expire again immediately.
  #
  # The crossing decision runs once, on the last entry, because the whole
  # transaction is one act and its last entry is the wallet's end state.
  @spec recurrence(String.t(), recurrence_request()) ::
          {:ok, map()} | {:error, term()}
  def recurrence(tenant_key, request) do
    repo = Config.repo()
    nested? = repo.in_transaction?()

    case repo.transaction(fn -> recurrence_locked(repo, tenant_key, request) end) do
      {:ok, %{outcomes: outcomes} = report} ->
        Enum.each(outcomes, &recurrence_effect(&1, nested?))
        {:ok, Map.delete(report, :outcomes)}

      {:error, {:skipped, reason}} ->
        {:ok, %{result: :skipped, reason: reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp recurrence_effect(outcome, nested?) do
    outcome = Map.put(outcome, :deferred, nested?)
    if nested?, do: defer(outcome), else: emit(outcome)
  end

  defp recurrence_locked(repo, tenant_key, request) do
    row = locked_row(repo, tenant_key)

    # The allowance, the cap and the catch-up are all defined over lots, so a
    # wallet the allocator does not own cannot be given one. Refused under the
    # lock rather than from the scan's snapshot, for the same reason
    # `expire_grant_locked/4` refuses there.
    if lots?(row) do
      recurrence_gate(repo, row, request)
    else
      repo.rollback({:skipped, :lots_disabled})
    end
  end

  defp recurrence_gate(repo, row, request) do
    case request.gate.(repo) do
      :ok -> recurrence_write(repo, row, request)
      {:skip, reason} -> repo.rollback({:skipped, reason})
    end
  end

  defp recurrence_write(repo, row, request) do
    now = lot_instant()

    case insert_recurrence(repo, row.tenant_key, request, now) do
      nil ->
        repo.rollback({:skipped, :duplicate})

      recurrence ->
        previous = previous_lots(repo, row.tenant_key, request.previous)
        carry = recurrence_carry(previous, request)

        {row, outcomes} = expire_all(repo, row, Enum.map(previous, & &1.id), now, [])
        {row, outcomes, grant} = recurrence_grant(repo, row, request, now, outcomes)
        {row, outcomes, rollover} = recurrence_rollover(repo, row, request, carry, now, outcomes)
        {row, outcomes} = recurrence_history(repo, row, request, [grant, rollover], now, outcomes)

        recurrence = finish_recurrence(repo, recurrence, grant, rollover, request)

        %{
          result: recurrence.state,
          recurrence: recurrence,
          tenant_key: row.tenant_key,
          amount: request.policy.amount,
          rollover_amount: carry,
          unused_before: unused(previous),
          outcomes: recurrence_outcomes(Enum.reverse(outcomes), repo)
        }
    end
  end

  # The crossing is decided once, on the entry that left the wallet in the state
  # it is now in. Deciding it on each entry in turn would write the flag from a
  # row copy the next entry then invalidates, and would announce a crossing for
  # an intermediate state no reader can ever observe: a historical period dips
  # below its threshold between the grant and the expiry that undoes it.
  defp recurrence_outcomes([], _repo), do: []

  defp recurrence_outcomes(outcomes, repo) do
    {leading, [last]} = Enum.split(outcomes, -1)
    Enum.map(leading, &Map.put(&1, :crossing, :none)) ++ [settle_outcome(repo, last)]
  end

  defp insert_recurrence(repo, tenant_key, request, now) do
    state = if request.historical?, do: :issued_and_expired, else: :granted

    {_count, returned} =
      repo.insert_all(
        CreditRecurrence,
        [
          %{
            id: Ecto.UUID.generate(),
            tenant_key: tenant_key,
            key: request.key,
            policy: request.policy_json,
            period_start: DateTime.truncate(request.period.start, :second),
            state: state,
            inserted_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:tenant_key, :key],
        returning: [:id, :key, :state, :period_start]
      )

    List.first(returned)
  end

  # Every lot the previous period produced, allowance and rollover alike, found
  # by the recurrence key each carries in its `source`. The rollover is capped
  # against the two together: taking it from the allowance lot alone would
  # under-carry a period that spent its allowance and left its carry unspent,
  # and taking it uncapped would compound. The cap is what stops compounding,
  # not the choice of lots.
  defp previous_lots(_repo, _tenant_key, nil), do: []

  defp previous_lots(repo, tenant_key, %{key: key}) do
    repo.all(
      from(l in CreditLot,
        where: l.tenant_key == ^tenant_key and fragment("?->>'recurrence_key'", l.source) == ^key,
        order_by: [asc: l.seq],
        lock: "FOR UPDATE"
      )
    )
  end

  # What the previous period did not spend, whether or not the expiry sweep has
  # already destroyed it. `available + expired` is invariant under this lot's own
  # expiry, which is what makes the carry the same number whichever of the sweep
  # and this transaction reached the lot first: expiry only ever moves value from
  # one of those two buckets to the other.
  defp unused(lots), do: Enum.reduce(lots, 0, &(&1.available + &1.expired + &2))

  defp recurrence_carry(_previous, %{previous: nil}), do: 0

  defp recurrence_carry(previous, %{previous: %{rollover: cap}}), do: min(unused(previous), cap)

  defp recurrence_grant(repo, row, request, now, outcomes) do
    outcome =
      write_lot_grant(repo, row, request.policy.amount, %{
        category: request.policy.category,
        reference: request.reference,
        expires_at: expires_at(request.policy.expires, request.period, now),
        metadata: request.metadata,
        source: request.source
      })

    {outcome.after, [outcome | outcomes], outcome}
  end

  defp recurrence_rollover(_repo, row, _request, 0, _now, outcomes), do: {row, outcomes, nil}

  defp recurrence_rollover(repo, row, request, carry, _now, outcomes) do
    outcome =
      write_lot_grant(repo, row, carry, %{
        category: request.policy.category,
        reference: request.reference <> ":rollover",
        # A carried lot always expires with the period it was carried into,
        # whatever the policy says about the allowance itself. It is last
        # period's money, granted one more period to be spent in.
        expires_at: request.period.end,
        metadata: Map.put(request.metadata, "rollover", true),
        source: Map.put(request.source, "rollover_from", request.previous.key)
      })

    {outcome.after, [outcome | outcomes], outcome}
  end

  # A period that had already ended when it was processed. The allowance is
  # real history, so it is written; it was never spendable, so it is destroyed
  # in the same transaction. `v1-release.md` 10.1: expired historical grants
  # enter ledger history as issued and expired rather than appearing as fresh
  # available funds.
  defp recurrence_history(_repo, row, %{historical?: false}, _grants, _now, outcomes),
    do: {row, outcomes}

  defp recurrence_history(repo, row, _request, grants, now, outcomes) do
    ids =
      grants
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&lot_of(repo, &1.txn.id))
      |> Enum.reject(&is_nil/1)

    expire_all(repo, row, ids, now, outcomes)
  end

  defp expire_all(_repo, row, [], _now, outcomes), do: {row, outcomes}

  defp expire_all(repo, row, [id | rest], now, outcomes) do
    case expire_lot_locked(repo, row, id, now) do
      # `:already_expired` (the sweep got here first, or a historical grant that
      # repaid its whole value into debt) and `:held` (a hold still reserves it,
      # and I12 turns that into `expired` when it is released) are both answers
      # rather than failures. Neither leaves value that this period may carry:
      # `unused/1` counted it before either could move it.
      {:refused, _reason} -> expire_all(repo, row, rest, now, outcomes)
      outcome -> expire_all(repo, outcome.after, rest, now, [outcome | outcomes])
    end
  end

  defp lot_of(repo, transaction_id) do
    repo.one(from(l in CreditLot, where: l.grant_transaction_id == ^transaction_id, select: l.id))
  end

  defp write_lot_grant(repo, row, amount, attrs) do
    Money.assert_range!(amount)

    source = Map.get(attrs, :source, %{})
    attrs = attrs |> Map.delete(:source) |> Map.merge(%{kind: :grant, amount: amount})

    grant_with_lots(repo, row, attrs, source)
  end

  defp expires_at(:never, _period, _now), do: nil
  defp expires_at(:period_end, period, _now), do: period.end
  defp expires_at({:seconds, seconds}, _period, now), do: DateTime.add(now, seconds, :second)

  # `rollover_from_id` names the recurrence a carry really came from, so it is
  # written only when one did. A period that carried nothing has no source to
  # name, and naming one anyway would make an audit read "this period's funds
  # came from that period" of a period that contributed nothing.
  defp finish_recurrence(repo, recurrence, grant, rollover, request) do
    changes = [granted_transaction_id: grant.txn.id] ++ rollover_from(rollover, request)

    {1, [updated]} =
      repo.update_all(
        from(r in CreditRecurrence, where: r.id == ^recurrence.id, select: r),
        set: changes
      )

    updated
  end

  defp rollover_from(nil, _request), do: []
  defp rollover_from(_outcome, %{previous: %{id: id}}), do: [rollover_from_id: id]

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

  # -- the low-balance crossing (inside the transaction) -----------------------

  # **The flag says "this crossing has been decided", not "this alert has been
  # delivered"**, and it is written under the balance row lock in the same
  # transaction as the balance it describes. Three consequences, all of them
  # the point of task 06.07's "avoid duplicate threshold alerts on replay":
  #
  #   * a wallet that stays below its threshold for five more debits alerts
  #     once, because the flag is already set when each of them evaluates;
  #   * a redelivered webhook that produces a deduplicated ledger row moves
  #     nothing and is refused evaluation outright;
  #   * a write the host rolls back takes the flag with it, so the next write
  #     decides the crossing afresh.
  #
  # A genuine second crossing (spendable returns to the threshold, then falls
  # again) clears the flag on the way up and sets a new one, whose id is the
  # transaction that caused it, on the way down.
  #
  # The trigger figure is **spendable**, not `balance - held`. On a cut-over
  # wallet those differ by credit past its `expires_at` and by outstanding debt,
  # and a tenant whose only remaining funds are on an expired lot is low on
  # money whatever the balance column says.
  @spec decide_crossing(module(), outcome()) :: {:alert, map()} | :none
  defp decide_crossing(_repo, %{duplicate: true}), do: :none

  defp decide_crossing(repo, %{after: row, txn: txn, spendable_after: spendable}) do
    threshold = row.low_balance_threshold || Config.credits_low_balance_threshold()

    case crossing_state(threshold, row.low_balance_crossing_id, spendable) do
      :raise -> raise_crossing(repo, row, txn, spendable)
      :clear -> clear_crossing(repo, row)
      :hold -> :none
    end
  end

  @spec crossing_state(integer() | nil, Ecto.UUID.t() | nil, integer()) ::
          :raise | :clear | :hold
  defp crossing_state(nil, nil, _spendable), do: :hold
  defp crossing_state(nil, _standing, _spendable), do: :clear

  defp crossing_state(threshold, nil, spendable) when spendable < threshold, do: :raise
  defp crossing_state(threshold, nil, _spendable) when is_integer(threshold), do: :hold

  defp crossing_state(threshold, _standing, spendable) when spendable >= threshold, do: :clear
  defp crossing_state(_threshold, _standing, _spendable), do: :hold

  @spec raise_crossing(module(), CreditBalance.t(), CreditTransaction.t(), integer()) ::
          {:alert, map()}
  defp raise_crossing(repo, row, txn, spendable) do
    write_crossing(repo, row, txn.id)

    {:alert,
     %{
       tenant_key: row.tenant_key,
       # `available` is kept and keeps its meaning, because it is what every
       # existing subscriber matches on. `spendable` is the figure the decision
       # was actually taken from, and on a legacy wallet the two are equal.
       available: row.balance - row.held,
       spendable: spendable,
       threshold: row.low_balance_threshold || Config.credits_low_balance_threshold(),
       crossing_id: txn.id
     }}
  end

  @spec clear_crossing(module(), CreditBalance.t()) :: :none
  defp clear_crossing(repo, row) do
    write_crossing(repo, row, nil)
    :none
  end

  # `update_all` on the primary key rather than a changeset on the struct the
  # caller is still holding: the row is already locked by this transaction, the
  # only column moving is this one, and writing through the struct would make
  # the caller's copy and the database disagree about every other column it has
  # since changed.
  @spec write_crossing(module(), CreditBalance.t(), Ecto.UUID.t() | nil) :: :ok
  defp write_crossing(repo, row, crossing_id) do
    {1, _} =
      repo.update_all(
        from(b in CreditBalance, where: b.id == ^row.id),
        set: [low_balance_crossing_id: crossing_id]
      )

    :ok
  end

  # -- deferral (the process-bound queue) -------------------------------------

  # The process dictionary, deliberately. Ecto's transaction scope is itself
  # process bound, so the queue and the transaction it belongs to have exactly
  # the same lifetime: a process that dies loses both, and there is no way for
  # one to outlive the other and describe a transaction that is gone. A named
  # table or an Agent would have to be told when the process died; this cannot
  # be told wrong.
  @deferred_key :aurora_meter_credits_deferred

  @doc false
  @spec defer(outcome()) :: :ok
  def defer(outcome) do
    Process.put(@deferred_key, deferred() ++ [outcome])
    :ok
  end

  @doc false
  @spec deferred() :: [outcome()]
  def deferred, do: Process.get(@deferred_key, [])

  @doc false
  @spec drain(keyword()) :: :ok
  def drain(opts) do
    queued = deferred()
    Process.delete(@deferred_key)

    if Keyword.get(opts, :discard, false) do
      :ok
    else
      Enum.each(queued, &emit/1)
    end
  end

  # -- post-commit side effects -----------------------------------------------

  @spec emit(outcome()) :: :ok
  defp emit(%{txn: txn, after: after_row} = outcome) do
    available_after = after_row.balance - after_row.held

    :telemetry.execute(
      [:aurora_meter, :credits, txn.kind],
      %{
        amount: if(outcome.duplicate, do: 0, else: txn.amount),
        balance_after: after_row.balance,
        available_after: available_after,
        spendable_after: outcome.spendable_after
      },
      %{
        tenant_key: txn.tenant_key,
        reference: txn.reference,
        category: txn.category,
        duplicate: outcome.duplicate,
        overrun: outcome.overrun,
        deferred: Map.get(outcome, :deferred, false)
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
           available: available_after,
           spendable: outcome.spendable_after,
           debt: after_row.debt,
           expired: after_row.expired
         }}
      )
    end

    low_balance(outcome.crossing)
  end

  @spec low_balance({:alert, map()} | :none) :: :ok
  defp low_balance(:none), do: :ok

  defp low_balance({:alert, event}) do
    PubSub.broadcast(
      Config.pubsub(),
      topic(event.tenant_key),
      {:aurora_meter, :low_balance, event}
    )

    deliver_alert(event, Config.credits_low_balance_handler())
  end

  # **The writer does not wait for the handler, and it took a measurement to
  # learn why that matters** (finding X269).
  #
  # The first implementation of this unit ran the handler in a task and then
  # blocked the writer on `Task.yield/2` until it answered. That satisfies the
  # contract on paper: a handler that raises or hangs cannot change the ledger
  # call's outcome. What it also does is hold the **writer** still while the
  # **handler** wants a database connection, and the writer may be holding one:
  # `AuroraMeter.Pro.Lock.with_lock/2` wraps the payment paths in
  # `Repo.checkout/1`, which pins a connection to the calling process for the
  # length of the callback. The handler then needs a *second*, concurrent
  # connection, and if the pool cannot spare one the two wait for each other
  # until the checkout queue gives up. With a single connection, which is what
  # `Ecto.Adapters.SQL.Sandbox` gives a test, it is a deadlock every time; with a
  # real pool it is one more concurrent connection, and the same deadlock at
  # exhaustion.
  #
  # So the wait moves into a supervised watcher of its own. The writer starts it
  # and returns, releasing whatever it held; the watcher runs the handler under
  # the same `async_nolink` plus `yield` plus `shutdown`, and emits the telemetry
  # when it knows the outcome. Every guarantee is kept and one is strengthened:
  # the handler cannot fail the write, cannot block it, and now cannot **delay**
  # it either.
  #
  # Two consequences, both documented. `[:aurora_meter, :credits, :low_balance]`
  # is asynchronous with respect to the ledger call's return, so a test waits for
  # it rather than reading it back. And two crossings in quick succession may
  # emit their events in either order, which is why each carries its own
  # `crossing_id`.
  #
  # The **PubSub broadcast above stays synchronous**, deliberately: it is the
  # ledger's own statement that a crossing happened, it needs no connection, and
  # a caller that wants a deterministic count of crossings counts those.
  @spec deliver_alert(map(), (map() -> term()) | nil) :: :ok
  defp deliver_alert(event, nil), do: emit_low_balance(event, :none)

  defp deliver_alert(event, handler) when is_function(handler, 1) do
    case Task.Supervisor.start_child(AuroraMeter.TaskSupervisor, fn ->
           emit_low_balance(event, supervised_handler(handler, event))
         end) do
      {:ok, _pid} ->
        :ok

      other ->
        # The supervisor is part of `AuroraMeter`'s own tree, so this is a host
        # that has not started it. Say so once and carry on: the write is
        # committed and the crossing is recorded either way.
        warn_handler(event, "could not be started: #{inspect(other)}")
        emit_low_balance(event, :exit)
    end
  end

  @spec emit_low_balance(map(), :ok | :none | :raised | :exit | :timeout) :: :ok
  defp emit_low_balance(event, outcome) do
    :telemetry.execute(
      [:aurora_meter, :credits, :low_balance],
      %{available: event.available, spendable: event.spendable, threshold: event.threshold},
      %{tenant_key: event.tenant_key, crossing_id: event.crossing_id, handler: outcome}
    )

    :ok
  end

  # `async_nolink` plus `yield` plus `shutdown`, which is the shape
  # `Reconciliation.decide/3` established for the hold reconciler in 05b, run
  # here inside the watcher rather than inside the writer. A host callback that
  # raises must not turn a committed settle into an exception at the call site
  # (finding L5), and one that never returns must be killable without the kill
  # propagating anywhere.
  @spec supervised_handler((map() -> term()), map()) :: :ok | :raised | :exit | :timeout
  defp supervised_handler(handler, event) do
    timeout = Config.credits_low_balance_handler_timeout()
    task = Task.Supervisor.async_nolink(AuroraMeter.TaskSupervisor, fn -> handler.(event) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, _returned} ->
        :ok

      {:exit, {exception, stacktrace}} when is_exception(exception) and is_list(stacktrace) ->
        warn_handler(event, "raised #{Exception.message(exception)}")
        :raised

      {:exit, reason} ->
        warn_handler(event, "exited: #{inspect(reason)}")
        :exit

      # `Task.yield/2` answers `nil` on a timeout and `Task.shutdown/2` answers
      # `nil` when the brutal kill got there first. Both are the same fact.
      nil ->
        warn_handler(event, "did not answer within #{timeout}ms and was killed")
        :timeout
    end
  end

  @spec warn_handler(map(), String.t()) :: :ok
  defp warn_handler(event, detail) do
    Logger.warning(
      "AuroraMeter.Credits: the low-balance handler #{detail} for tenant " <>
        "#{inspect(event.tenant_key)} (crossing #{inspect(event.crossing_id)}). The ledger " <>
        "write stands and no alert was delivered; the crossing is already recorded, so no " <>
        "later write will re-send it. See docs/credits.md, \"One alert per crossing\"."
    )
  end
end
