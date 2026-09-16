defmodule AuroraMeterExampleAi.Ops do
  @moduledoc """
  What the `/ops` page shows: the conservation identity, the outbox, the two
  reporting sources side by side, and any orphaned event.

  Every figure here is read through a public Aurora Meter function or out of
  this application's own tables. Nothing queries an `aurora_meter_*` table
  directly, which is not fussiness: those tables are the library's, their shape
  changes with its schema version, and a host that reads them has quietly taken
  a dependency nobody will remember at upgrade time.
  """

  import Ecto.Query

  alias AuroraMeter.Credits
  alias AuroraMeter.Exporter.Journal
  alias AuroraMeter.Schema.CreditTransaction
  alias AuroraMeterExampleAi.Accounts.Scope
  alias AuroraMeterExampleAi.Generations.Generation
  alias AuroraMeterExampleAi.Orgs
  alias AuroraMeterExampleAi.Repo
  alias AuroraMeterExampleAi.SampleOutbox.Item
  alias AuroraMeterExampleAi.Tenancy

  @typedoc """
  The conservation check. `holds` is what the ledger says is reserved and
  `balance` what it says is owned; `available` must be the difference, and both
  totals must equal the sum of every entry ever written for this wallet.
  """
  @type conservation :: %{
          ledger_balance: integer(),
          ledger_held: integer(),
          summary_balance: integer(),
          summary_held: integer(),
          summary_available: integer(),
          entries: non_neg_integer(),
          balance_holds: boolean(),
          held_holds: boolean(),
          available_holds: boolean(),
          holds: boolean()
        }

  @doc """
  Adds up every ledger entry this organisation has and compares the totals with
  what `AuroraMeter.Credits.summary/1` reports.

  `amount` is the signed delta an entry applied to the balance and `held_delta`
  the delta it applied to the reserved figure, so summing both columns over
  every entry ever written must reproduce the two figures a dashboard shows. It
  is a snapshot taken with several queries rather than a serialised total, and
  that is stated on the page: a generation completing between two of the reads
  moves one figure and not the other.
  """
  @spec conservation(Scope.t()) :: conservation()
  def conservation(%Scope{} = scope) do
    org = Tenancy.org!(scope)
    tenant_key = Tenancy.to_key(org)

    entries = Credits.history(org, kinds: CreditTransaction.kinds(), limit: 1_000)
    ledger_balance = Enum.reduce(entries, 0, &(&1.amount + &2))
    ledger_held = Enum.reduce(entries, 0, &(&1.held_delta + &2))

    summary = Credits.summary(org)

    %{
      tenant_key: tenant_key,
      ledger_balance: ledger_balance,
      ledger_held: ledger_held,
      summary_balance: summary.balance,
      summary_held: summary.held,
      summary_available: summary.available,
      entries: length(entries),
      balance_holds: ledger_balance == summary.balance,
      held_holds: ledger_held == summary.held,
      available_holds: summary.balance - summary.held == summary.available
    }
    |> then(fn map ->
      Map.put(
        map,
        :holds,
        map.balance_holds and map.held_holds and map.available_holds
      )
    end)
  end

  @doc "This organisation's credit lots, in the order the next spend will draw on them."
  @spec lots(Scope.t()) :: [map()]
  def lots(%Scope{} = scope) do
    Credits.Lots.list(Tenancy.org!(scope), states: :all, limit: 50)
  end

  @doc "The allocation trail: which lot each movement came out of, oldest first."
  @spec allocations(Scope.t(), keyword()) :: [map()]
  def allocations(%Scope{} = scope, opts \\ []) do
    Credits.Lots.allocations(Tenancy.org!(scope), Keyword.put_new(opts, :limit, 100))
  end

  @doc "How many outbox items this organisation has in each state."
  @spec outbox_states(Scope.t()) :: %{String.t() => non_neg_integer()}
  def outbox_states(%Scope{} = scope) do
    scope
    |> outbox_scope()
    |> group_by([i], i.state)
    |> select([i], {i.state, count(i.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "This organisation's outbox items, newest first."
  @spec outbox_items(Scope.t(), keyword()) :: [Item.t()]
  def outbox_items(%Scope{} = scope, opts \\ []) do
    scope
    |> outbox_scope()
    |> order_by([i], desc: i.inserted_at)
    |> limit(^Keyword.get(opts, :limit, 50))
    |> Repo.all()
  end

  @doc """
  What the reference exporter was actually handed for this organisation.

  The journal lives in an `Agent` and is lost with the node. It is a dry run and
  a teaching aid, never a record of what was billed.
  """
  @spec deliveries(Scope.t()) :: [map()]
  def deliveries(%Scope{} = scope) do
    key = Tenancy.to_key(Tenancy.org!(scope))

    Journal.deliveries()
    |> Enum.filter(&(&1.item.tenant_key == key))
  rescue
    # The journal is optional: a host that has not started it should see an
    # empty list rather than a crashed operations page.
    _error -> []
  end

  @doc """
  The two reporting sources, side by side.

  `:tokens` is declared `feature_sources: %{tokens: :events}`, so its billable
  fact is the durable event and its counter is a projection of those events.
  `:images` is left buffered: it lives in ETS, it is flushed on an interval,
  and it never becomes an event. The last figure is the one worth looking at:
  the outbox has seen an image event **zero** times, and it always will.
  """
  @spec sources(Scope.t()) :: map()
  def sources(%Scope{} = scope) do
    org = Tenancy.org!(scope)

    %{
      tokens_counter: AuroraMeter.usage(org, :tokens),
      tokens_outbox_quantity: outbox_quantity(scope, "tokens"),
      tokens_outbox_rows: outbox_rows(scope, "tokens"),
      images_counter: AuroraMeter.usage(org, :images),
      images_outbox_rows: outbox_rows(scope, "images"),
      quota_images: AuroraMeter.quota(org, :images),
      quota_tokens: AuroraMeter.quota(org, :tokens)
    }
  end

  @doc """
  Outbox items whose event has no `generations` row.

  This is the orphan: `AuroraMeter.record/4` committed the event and its export
  intent in one transaction, and this application died before it wrote its own
  row. `mix sample.repair` rebuilds what can be rebuilt.
  """
  @spec orphans(Scope.t()) :: [Item.t()]
  def orphans(%Scope{} = scope) do
    known =
      Generation
      |> Orgs.scope_query(scope)
      |> where([g], not is_nil(g.event_id))
      |> select([g], g.event_id)

    scope
    |> outbox_scope()
    |> where([i], i.event_id not in subquery(known))
    |> order_by([i], asc: i.inserted_at)
    |> Repo.all()
  end

  @spec outbox_scope(Scope.t()) :: Ecto.Query.t()
  defp outbox_scope(%Scope{} = scope) do
    # The outbox is keyed by the Aurora Meter tenant key rather than by
    # `org_id`, because that is the identifier the library hands the callback.
    # It is derived from the session scope exactly like every other query here.
    key = Tenancy.to_key(Tenancy.org!(scope))
    from(i in Item, where: i.tenant_key == ^key)
  end

  # `sum/1` over a bigint column comes back from Postgres as `numeric`, which
  # Ecto hands over as a `Decimal`. Comparing that with the integer the counter
  # reports is always false, whatever the two figures are, so the cast is not
  # tidiness: without it the conservation check on the operations page would
  # silently never agree.
  defp outbox_quantity(scope, feature) do
    scope
    |> outbox_scope()
    |> where([i], i.feature == ^feature)
    |> select([i], type(coalesce(sum(i.quantity), 0), :integer))
    |> Repo.one()
  end

  defp outbox_rows(scope, feature) do
    scope
    |> outbox_scope()
    |> where([i], i.feature == ^feature)
    |> select([i], count(i.id))
    |> Repo.one()
  end
end
