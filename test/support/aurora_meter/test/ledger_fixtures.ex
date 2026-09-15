defmodule AuroraMeter.Test.LedgerFixtures do
  @moduledoc """
  Populated 0.4.0 wallets, built by calling the real legacy ledger (build unit
  06b).

  Every shape below is produced by `AuroraMeter.Credits` against a wallet whose
  `lots_enabled_at` is null, which is the legacy writer. Nothing is inserted by
  hand, so the balance row and every `balance_after` on every row are what the
  shipped arithmetic really produced, and a fixture cannot quietly encode what
  the author believed that arithmetic did. That is the whole point: the wallet
  migration is checked against these figures, so a fixture that invented them
  would be checking the migration against itself.

  ## References are scoped to their wallet

  `(kind, reference)` is unique across the whole table, not per tenant, so two
  wallets of the same shape in one test would collide on the second grant.
  Every name below is therefore suffixed with the tenant key by `ref/2`, and a
  Pro-shaped reference keeps its prefix and its colons so the migration's
  provenance parsing sees the real thing (`refund:pi_x_org_7:200`, not
  `org_7:refund:pi_x:200`).

  ## Two helpers change rows after the fact

  Both model something a real database has rather than something a test wants:

    * `age!/2` nulls `hold_transaction_id` on every row, because every row
      written before core schema version 9 has none. Without it the backfill
      has nothing to backfill and its test proves nothing. With
      `promotional_after: :null` it also nulls that column, which is the shape
      of every row written before version 4 (finding L10).
    * `corrupt!/3` and `swap_inserted_at!/3` produce the histories the
      migration must **refuse**: an orphan settle, a row kind nothing writes, a
      tampered expiry, two rows stamped in the wrong order. Those cannot be
      produced through the API, which is exactly why refusing them matters.
  """

  import Ecto.Query

  alias AuroraMeter.Clock
  alias AuroraMeter.Config
  alias AuroraMeter.Credits
  alias AuroraMeter.Schema.CreditBalance
  alias AuroraMeter.Schema.CreditTransaction

  @dollar 1_000_000

  # Far enough out that a pinned `expire_due/1` in a fixture never reaches a
  # grant belonging to another wallet in the same test.
  @never ~U[2099-01-01 00:00:00Z]
  @soon ~U[2026-02-01 00:00:00Z]
  @sooner ~U[2026-01-01 00:00:00Z]
  @due ~U[2020-06-01 00:00:00Z]
  @after_due ~U[2020-07-01 00:00:00Z]

  @shapes [
    :paid_only,
    :promotional_overlap,
    :promotional_no_expiry,
    :partial_expiry,
    :pending_hold,
    :settled_overrun,
    :released_hold,
    :debits,
    :refund,
    :dispute,
    :reconciled,
    :reinstated,
    :grant_on_debt,
    :pre_v4
  ]

  @doc "Every wallet shape `build!/2` knows how to build."
  @spec shapes() :: [atom()]
  def shapes, do: @shapes

  @doc "One micro-dollar dollar, for readable fixtures."
  @spec dollar() :: pos_integer()
  def dollar, do: @dollar

  @doc """
  The reference `name` takes on `tenant`.

  `(kind, reference)` is globally unique, so a fixture name has to carry its
  wallet. The suffix keeps the Stripe identifier shape (`pi_...`) so the
  migration's payment-intent parsing is exercised for real.
  """
  @spec ref(String.t(), String.t()) :: String.t()
  def ref(tenant, name), do: name <> "_" <> String.replace(tenant, ~r/[^A-Za-z0-9_]/, "_")

  @doc """
  Builds `shape` on `tenant` through the real legacy ledger and returns
  `tenant`.
  """
  @spec build!(atom(), String.t()) :: String.t()
  def build!(shape, tenant) do
    apply(__MODULE__, :"build_#{shape}", [tenant])

    # Every row a 0.4.0 database holds has a null `hold_transaction_id`: the
    # column arrives with version 9. Ageing the wallet here rather than in the
    # test that happens to care is what stops the backfill's own test passing
    # against rows that were already filled in.
    age!(tenant)
    tenant
  end

  @doc false
  @spec build_paid_only(String.t()) :: :ok
  def build_paid_only(tenant) do
    grant!(tenant, 5 * @dollar, "pi_paid_a")
    grant!(tenant, 3 * @dollar, "pi_paid_b")
    grant!(tenant, 2 * @dollar, "top_up_manual")
    debit!(tenant, 6 * @dollar, "job_1")
    :ok
  end

  @doc false
  @spec build_promotional_overlap(String.t()) :: :ok
  def build_promotional_overlap(tenant) do
    promo!(tenant, 3 * @dollar, "promo_a", @sooner)
    promo!(tenant, 5 * @dollar, "promo_b", @soon)
    grant!(tenant, 10 * @dollar, "pi_overlap")
    debit!(tenant, 6 * @dollar, "job_overlap")
    :ok
  end

  @doc false
  @spec build_promotional_no_expiry(String.t()) :: :ok
  def build_promotional_no_expiry(tenant) do
    promo!(tenant, 4 * @dollar, "promo_forever", nil)
    promo!(tenant, 2 * @dollar, "promo_dated", @never)
    grant!(tenant, 1 * @dollar, "pi_small")
    debit!(tenant, 3 * @dollar, "job_no_expiry")
    :ok
  end

  # A grant that expires while a hold covers part of it: the legacy sweep
  # expires only the spendable part, leaves `expired_at` unset, and finishes
  # the job on a later pass once the hold has been released. This is finding
  # L7's partial-expiry reference and invariant I12's shape in one wallet.
  @doc false
  @spec build_partial_expiry(String.t()) :: :ok
  def build_partial_expiry(tenant) do
    promo!(tenant, 10 * @dollar, "promo_due", @due)
    hold!(tenant, 4 * @dollar, "hold_over_expiry")
    {:ok, _n} = Credits.expire_due(@after_due)
    release!(tenant, "hold_over_expiry")
    {:ok, _n} = Credits.expire_due(@after_due)
    :ok
  end

  # **The legacy expiry guard is wallet wide, not per grant.**
  # `expire_locked/4` clamps by `max(balance - held, 0)`, so with a second
  # grant covering the held amount it destroys the soonest-expiring grant in
  # full although a hold was reserving part of it. The hold then reserves
  # credit that no longer exists, which the single `held` figure cannot see and
  # a lot table cannot express. Found by the generated-history property, and
  # built here so the refusal has a wallet of its own (finding X261).
  @doc false
  @spec build_expiry_over_hold(String.t()) :: :ok
  def build_expiry_over_hold(tenant) do
    promo!(tenant, 1 * @dollar, "promo_soonest", @due)
    promo!(tenant, 10 * @dollar, "promo_later", @never)
    hold!(tenant, 1 * @dollar, "hold_on_soonest")
    {:ok, _n} = Credits.expire_due(@after_due)
    :ok
  end

  @doc false
  @spec build_pending_hold(String.t()) :: :ok
  def build_pending_hold(tenant) do
    grant!(tenant, 6 * @dollar, "pi_pending")
    promo!(tenant, 2 * @dollar, "promo_pending", @never)
    hold!(tenant, 3 * @dollar, "hold_still_open")
    :ok
  end

  @doc false
  @spec build_settled_overrun(String.t()) :: :ok
  def build_settled_overrun(tenant) do
    grant!(tenant, 4 * @dollar, "pi_overrun")
    hold!(tenant, 2 * @dollar, "hold_overrun")
    settle!(tenant, "hold_overrun", 6 * @dollar)
    :ok
  end

  @doc false
  @spec build_released_hold(String.t()) :: :ok
  def build_released_hold(tenant) do
    grant!(tenant, 4 * @dollar, "pi_released")
    promo!(tenant, 1 * @dollar, "promo_released", @never)
    hold!(tenant, 2 * @dollar, "hold_released")
    release!(tenant, "hold_released")
    debit!(tenant, 1 * @dollar, "job_released")
    :ok
  end

  @doc false
  @spec build_debits(String.t()) :: :ok
  def build_debits(tenant) do
    grant!(tenant, 5 * @dollar, "pi_debits")
    debit!(tenant, 2 * @dollar, "job_a")
    debit!(tenant, 2 * @dollar, "job_b")
    debit!(tenant, 1 * @dollar, "job_c")
    :ok
  end

  @doc false
  @spec build_refund(String.t()) :: :ok
  def build_refund(tenant) do
    intent = ref(tenant, "pi_refunded")
    grant!(tenant, 5 * @dollar, "pi_refunded")
    debit!(tenant, 1 * @dollar, "job_refund")
    reverse!(tenant, 2 * @dollar, "refund:#{intent}:200", intent, "refund")
    :ok
  end

  @doc false
  @spec build_dispute(String.t()) :: :ok
  def build_dispute(tenant) do
    intent = ref(tenant, "pi_disputed")
    grant!(tenant, 5 * @dollar, "pi_disputed")
    reverse!(tenant, 3 * @dollar, "dispute:#{intent}:du_1:300", intent, "dispute")
    :ok
  end

  @doc false
  @spec build_reconciled(String.t()) :: :ok
  def build_reconciled(tenant) do
    intent = ref(tenant, "pi_reconciled")
    grant!(tenant, 5 * @dollar, "pi_reconciled")
    debit!(tenant, 1 * @dollar, "job_reconciled")

    reverse!(
      tenant,
      2 * @dollar,
      "reconciled:#{intent}:sync:100:0:200",
      intent,
      "payment_reconciliation"
    )

    adjustment!(tenant, 1 * @dollar, "reconciled_restore:#{intent}:sync:100:0:100")
    :ok
  end

  @doc false
  @spec build_reinstated(String.t()) :: :ok
  def build_reinstated(tenant) do
    intent = ref(tenant, "pi_reinstated")
    grant!(tenant, 5 * @dollar, "pi_reinstated")
    reverse!(tenant, 3 * @dollar, "dispute:#{intent}:du_2:300", intent, "dispute")
    adjustment!(tenant, 3 * @dollar, "reinstated:#{intent}:du_2:300")
    :ok
  end

  # A settlement above its hold drives the balance negative, and a promotional
  # grant then lands on it. The legacy ledger attributed only the part above
  # zero to the grant; the lot model gives the lot its whole amount and repays
  # the debt out of it. The two leave the same figure, which is what the
  # reconciliation has to show.
  @doc false
  @spec build_grant_on_debt(String.t()) :: :ok
  def build_grant_on_debt(tenant) do
    grant!(tenant, 2 * @dollar, "pi_debt")
    hold!(tenant, 1 * @dollar, "hold_debt")
    settle!(tenant, "hold_debt", 5 * @dollar)
    promo!(tenant, 6 * @dollar, "promo_on_debt", @never)
    :ok
  end

  # The shape of a database that has been through version 4 without a backfill:
  # the rows written before it carry no `promotional_after` at all (L10).
  @doc false
  @spec build_pre_v4(String.t()) :: :ok
  def build_pre_v4(tenant) do
    promo!(tenant, 4 * @dollar, "promo_pre_v4", @never)
    grant!(tenant, 6 * @dollar, "pi_pre_v4")
    debit!(tenant, 5 * @dollar, "job_pre_v4")
    age!(tenant, promotional_after: :null)
    :ok
  end

  @doc """
  Makes `tenant`'s rows look like the version they were really written at.

  Options:

    * `:promotional_after` - `:null` nulls the column on every row, which is
      what a row written before core schema version 4 carries.
    * `:hold_transaction_id` - defaults to `:null`, which is what every row
      written before version 9 carries. Pass `:keep` to leave it.
  """
  @spec age!(String.t(), keyword()) :: :ok
  def age!(tenant, opts \\ []) do
    unless Keyword.get(opts, :hold_transaction_id, :null) == :keep do
      update_rows!(tenant, hold_transaction_id: nil)
    end

    if Keyword.get(opts, :promotional_after) == :null do
      update_rows!(tenant, promotional_after: nil)
    end

    :ok
  end

  @doc """
  Swaps the `inserted_at` of the rows named `a` and `b`.

  A wall clock steps backwards, and the ledger stamped `inserted_at` from one,
  so two rows really can carry timestamps in the opposite order to their commit
  order (findings L20, X213). This produces that wallet without pretending it
  is rare.
  """
  @spec swap_inserted_at!(String.t(), String.t(), String.t()) :: :ok
  def swap_inserted_at!(tenant, a, b) do
    first = row!(tenant, a)
    second = row!(tenant, b)

    set!(first.id, inserted_at: second.inserted_at)
    set!(second.id, inserted_at: first.inserted_at)
    :ok
  end

  @doc """
  Writes a history the ledger's own API cannot produce.

  These are the shapes the migration exists to refuse: a settlement with no
  hold, a row kind nothing writes, an expiry that names no grant, an expiry
  larger than its grant, and a balance row that does not match its own log.
  Each is a real possibility in a database that has been hand repaired, and a
  refusal nobody can demonstrate is not a refusal.
  """
  @spec corrupt!(String.t(), atom(), keyword()) :: :ok
  def corrupt!(tenant, kind, opts \\ [])

  def corrupt!(tenant, :orphan_settle, _opts) do
    insert_row!(tenant, %{
      kind: :settle,
      amount: 0,
      held_delta: 0,
      settled_amount: 0,
      reference: ref(tenant, "orphan_settle")
    })
  end

  def corrupt!(tenant, :orphan_release, _opts) do
    insert_row!(tenant, %{
      kind: :release,
      amount: 0,
      held_delta: 0,
      reference: ref(tenant, "orphan_release")
    })
  end

  # **A grant whose category the fold has no rule for, and it has to be a
  # category rather than a kind.** Until build unit 06c this fixture inserted a
  # `kind: :reverse` row, which was then the one kind in
  # `Schema.CreditTransaction.kinds/0` that `LotMigration.step/2` had no clause
  # for. 06c made `Credits.reverse/4` write exactly that kind, so the fold
  # gained a clause for it and the dispatcher became total over the seven kinds
  # (finding X266). `:unsupported_row` is still reachable, and this is now the
  # shape that reaches it: a `:grant` carrying the reversal category, which the
  # schema admits and which no writer produces.
  def corrupt!(tenant, :unsupported_row, _opts) do
    insert_row!(tenant, %{
      kind: :grant,
      category: :reversal,
      amount: 0,
      held_delta: 0,
      reference: ref(tenant, "unsupported")
    })
  end

  def corrupt!(tenant, :expire_without_grant_id, _opts) do
    repo().update_all(
      from(t in CreditTransaction, where: t.tenant_key == ^tenant and t.kind == ^:expire),
      set: [metadata: %{}]
    )

    :ok
  end

  def corrupt!(tenant, :expire_over_lot, _opts) do
    row =
      repo().one(
        from(t in CreditTransaction,
          where: t.tenant_key == ^tenant and t.kind == ^:expire,
          order_by: [asc: t.seq],
          limit: 1
        )
      )

    set!(row.id, amount: row.amount * 10)
  end

  def corrupt!(tenant, :balance_row, opts) do
    repo().query!(
      "UPDATE aurora_meter_credit_balances SET balance = balance + $2 WHERE tenant_key = $1",
      [tenant, Keyword.get(opts, :by, 1)]
    )

    :ok
  end

  def corrupt!(tenant, :balance_after, opts) do
    row = row!(tenant, Keyword.fetch!(opts, :reference))
    set!(row.id, balance_after: row.balance_after + Keyword.get(opts, :by, 1))
  end

  @doc """
  The ledger row named `name` for `tenant`, whatever its kind.

  Accepts either the scoped reference or the bare fixture name.
  """
  @spec row!(String.t(), String.t()) :: CreditTransaction.t()
  def row!(tenant, name) do
    case find_row(tenant, name) do
      nil -> repo().one!(query_for(tenant, ref(tenant, name)))
      row -> row
    end
  end

  @doc "Every ledger row for `tenant`, in `seq` order."
  @spec rows(String.t()) :: [CreditTransaction.t()]
  def rows(tenant) do
    repo().all(
      from(t in CreditTransaction, where: t.tenant_key == ^tenant, order_by: [asc: t.seq])
    )
  end

  @doc "Every ledger row for `tenant`, in the order the ledger itself used."
  @spec rows_by_inserted_at(String.t()) :: [CreditTransaction.t()]
  def rows_by_inserted_at(tenant) do
    repo().all(
      from(t in CreditTransaction,
        where: t.tenant_key == ^tenant,
        order_by: [asc: t.inserted_at, asc: t.id]
      )
    )
  end

  # -- the legacy API ---------------------------------------------------------

  defp grant!(tenant, amount, name, opts \\ []) do
    {:ok, txn} = Credits.grant(tenant, amount, Keyword.put(opts, :reference, ref(tenant, name)))
    txn
  end

  defp promo!(tenant, amount, name, expires_at),
    do: grant!(tenant, amount, name, category: :promotional, expires_at: expires_at)

  defp adjustment!(tenant, amount, reference) do
    {:ok, txn} =
      Credits.grant(tenant, amount,
        reference: reference,
        category: :adjustment,
        metadata: %{"source" => "dispute_reinstated"}
      )

    txn
  end

  defp debit!(tenant, amount, name) do
    {:ok, txn} = Credits.debit(tenant, amount, ref(tenant, name))
    txn
  end

  defp hold!(tenant, amount, name) do
    {:ok, txn} = Credits.hold(tenant, amount, ref(tenant, name))
    txn
  end

  defp release!(tenant, name) do
    {:ok, txn} = Credits.release(ref(tenant, name))
    txn
  end

  defp settle!(tenant, name, actual) do
    {:ok, txn} = Credits.settle(ref(tenant, name), actual)
    txn
  end

  defp reverse!(tenant, amount, reference, intent, source) do
    {:ok, txn} =
      Credits.reverse(tenant, amount, reference, %{
        "source" => source,
        "payment_intent_id" => intent
      })

    txn
  end

  # -- direct writes, for histories the API cannot produce --------------------

  defp insert_row!(tenant, attrs) do
    row = repo().one(from(b in CreditBalance, where: b.tenant_key == ^tenant))

    entry =
      Map.merge(
        %{
          tenant_key: tenant,
          balance_after: row.balance,
          held_after: row.held,
          promotional_after: row.promotional,
          metadata: %{},
          inserted_at: Clock.now()
        },
        attrs
      )

    %CreditTransaction{}
    |> CreditTransaction.changeset(entry)
    |> Ecto.Changeset.put_change(:inserted_at, entry.inserted_at)
    |> repo().insert!()

    :ok
  end

  defp find_row(tenant, reference), do: repo().one(query_for(tenant, reference))

  defp query_for(tenant, reference) do
    from(t in CreditTransaction,
      where: t.tenant_key == ^tenant and t.reference == ^reference,
      limit: 1
    )
  end

  defp update_rows!(tenant, set) do
    repo().update_all(from(t in CreditTransaction, where: t.tenant_key == ^tenant), set: set)
    :ok
  end

  defp set!(id, set) do
    repo().update_all(from(t in CreditTransaction, where: t.id == ^id), set: set)
    :ok
  end

  defp repo, do: Config.repo()
end
