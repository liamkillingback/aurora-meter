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

  alias AuroraMeter.Config
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditTransaction
  alias Phoenix.PubSub

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
          apply_entry(repo, row, %{
            kind: :grant,
            amount: amount,
            category: category,
            reference: reference,
            expires_at: Keyword.get(opts, :expires_at),
            metadata: Map.new(Keyword.get(opts, :metadata, %{}))
          })
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

      cond do
        find(repo, tenant_key, :hold, reference) -> repo.rollback(:duplicate_reference)
        not sufficient?(row, amount) -> repo.rollback(:insufficient_credits)
        true -> :ok
      end

      apply_entry(repo, row, %{
        kind: :hold,
        amount: 0,
        held_delta: amount,
        reference: reference,
        status: :pending,
        metadata: Map.new(Keyword.get(opts, :metadata, %{}))
      })
    end)
    |> duplicate_reference_error()
  end

  @spec settle(String.t(), non_neg_integer(), keyword()) ::
          {:ok, CreditTransaction.t()} | {:error, :not_found | :already_settled}
  def settle(reference, actual, opts) do
    transact(fn repo ->
      hold = pending_hold!(repo, reference)
      row = locked_row(repo, hold.tenant_key)

      outcome =
        apply_entry(repo, row, %{
          kind: :settle,
          amount: -actual,
          held_delta: -hold.held_delta,
          reference: reference,
          settled_amount: actual,
          metadata: Map.new(Keyword.get(opts, :metadata, %{}))
        })

      close_hold!(repo, hold, status: :settled, settled_amount: actual)
      %{outcome | overrun: actual > hold.held_delta}
    end)
  end

  @spec release(String.t()) ::
          {:ok, CreditTransaction.t()} | {:error, :not_found | :already_settled}
  def release(reference) do
    transact(fn repo ->
      hold = pending_hold!(repo, reference)
      row = locked_row(repo, hold.tenant_key)

      outcome =
        apply_entry(repo, row, %{
          kind: :release,
          amount: 0,
          held_delta: -hold.held_delta,
          reference: reference
        })

      close_hold!(repo, hold, status: :released)
      outcome
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

      cond do
        find(repo, tenant_key, :debit, reference) -> repo.rollback(:duplicate_reference)
        allow_negative? -> :ok
        not sufficient?(row, amount) -> repo.rollback(:insufficient_credits)
        true -> :ok
      end

      apply_entry(repo, row, %{
        kind: :debit,
        category: category,
        amount: -amount,
        reference: reference,
        metadata: Map.new(metadata)
      })
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
  """
  @spec expire_due(DateTime.t()) :: {:ok, non_neg_integer()}
  def expire_due(now) do
    repo = Config.repo()
    now = DateTime.truncate(now, :second)

    due =
      repo.all(
        from(t in CreditTransaction,
          where:
            t.kind == ^:grant and t.category == ^:promotional and not is_nil(t.expires_at) and
              t.expires_at <= ^now and is_nil(t.expired_at),
          select: t.id
        )
      )

    count =
      Enum.count(due, fn id ->
        match?({:ok, _txn}, expire_grant(id, now))
      end)

    {:ok, count}
  end

  @spec expire_grant(Ecto.UUID.t(), DateTime.t()) ::
          {:ok, CreditTransaction.t()} | {:error, :already_expired}
  defp expire_grant(id, now) do
    transact(fn repo ->
      grant =
        repo.one!(from(t in CreditTransaction, where: t.id == ^id, lock: "FOR UPDATE"))

      if grant.expired_at, do: repo.rollback(:already_expired)

      row = locked_row(repo, grant.tenant_key)

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
      if amount == 0 and not fully_expired?, do: repo.rollback(:held)

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
    end)
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
  defp remaining_on_grant(repo, grant, row) do
    live =
      repo.all(
        from(t in CreditTransaction,
          where:
            t.tenant_key == ^grant.tenant_key and t.kind == ^:grant and
              t.category == ^:promotional and is_nil(t.expired_at),
          order_by: [asc_nulls_last: t.expires_at, asc: t.inserted_at, asc: t.id],
          select: %{id: t.id, amount: t.amount}
        )
      )

    granted = live |> Enum.map(& &1.amount) |> Enum.sum()
    consumed = max(granted - row.promotional, 0)
    earlier = live |> Enum.take_while(&(&1.id != grant.id)) |> Enum.map(& &1.amount) |> Enum.sum()

    grant.amount
    |> Kernel.-(max(consumed - earlier, 0))
    |> max(0)
    |> min(grant.amount)
  end

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

    case repo.transaction(fn -> fun.(repo) end) do
      {:ok, outcome} ->
        emit(outcome)
        {:ok, outcome}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Ensures the tenant has a balance row and returns it locked for the rest of
  # the transaction. Every write to a tenant's ledger serialises on this lock;
  # holds and debits are checked against the locked row, which is what makes
  # "exactly ten $0.10 holds against $1.00" true under concurrency.
  @spec locked_row(module(), String.t()) :: CreditBalance.t()
  defp locked_row(repo, tenant_key) do
    now = DateTime.utc_now()

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
        inserted_at: DateTime.utc_now()
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
  @spec pending_hold!(module(), String.t()) :: CreditTransaction.t()
  defp pending_hold!(repo, reference) do
    query =
      from(t in CreditTransaction,
        where: t.kind == ^:hold and t.reference == ^reference,
        lock: "FOR UPDATE"
      )

    case repo.one(query) do
      nil -> repo.rollback(:not_found)
      %CreditTransaction{status: :pending} = hold -> hold
      %CreditTransaction{} -> repo.rollback(:already_settled)
    end
  end

  @spec close_hold!(module(), CreditTransaction.t(), keyword()) :: CreditTransaction.t()
  defp close_hold!(repo, hold, changes) do
    hold |> Ecto.Changeset.change(changes) |> repo.update!()
  end

  # A unique-index violation on the reference (a duplicate from another tenant,
  # which the in-transaction lookup cannot see) is the same error to the caller;
  # it is the only changeset error a hold or debit can produce.
  @spec duplicate_reference_error({:ok, CreditTransaction.t()} | {:error, term()}) ::
          {:ok, CreditTransaction.t()} | {:error, term()}
  defp duplicate_reference_error({:error, %Ecto.Changeset{}}), do: {:error, :duplicate_reference}
  defp duplicate_reference_error(result), do: result

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
