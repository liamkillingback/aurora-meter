defmodule AuroraMeter.Credits.Lots do
  @moduledoc """
  Reads a tenant's credit lots and the allocation trail that moved them.

  A **lot** is one grant's worth of credit, with the five buckets its value can
  be in. A grant creates exactly one and nothing ever merges two, so "which
  grant paid for this" and "which payment funded this grant" both have an
  answer. An **allocation** is one movement of value between two buckets of one
  lot, naming the ledger entry that caused it.

  This module is how a human answers "where did the money go" without reading
  `aurora_meter_credit_transactions` by hand, and it is the only supported way
  for anything outside `AuroraMeter.Credits` to read lot data.

      alias AuroraMeter.Credits.Lots

      Lots.list(org)                              # open lots, in spend order
      Lots.list(org, states: :all)                # including exhausted and reversed
      Lots.get(org, "stripe:pi_123")              # by grant reference, or by lot id
      Lots.for_source(org, %{payment_intent_id: "pi_123"})
      Lots.allocations(org, lot_id: lot.id)       # what moved, in order

  ## Spend order

  `list/2` returns lots in the order the next debit will consume them:
  promotional before paid (adjustment sorts with paid), then the earliest
  non-null `expires_at`, then the oldest grant, then the ordering key. A reader
  therefore sees what the next spend will take, not merely what exists. The
  order is fixed by the engine and **no option changes it**: a caller that could
  choose the spend order could choose which of two customers' money is spent
  first, which is not a display concern.

  `order: :granted_at` re-sorts the same lots for a human reading a history. It
  changes what the list looks like, never what a debit does.

  ## A snapshot, not a transaction

  Everything here is read only and takes no lock, so a lot's quantities may
  differ a microsecond after it is returned. That is the right trade for a
  support screen and the wrong one for a decision: the only read that is
  consistent with a write is one made inside the transaction that writes, and
  `AuroraMeter.Credits`' own operations make it under the balance row's lock.
  Never compute an amount to write from a figure read here.

  ## Legacy wallets

  A wallet that has not been cut over to lots (`lots_enabled_at IS NULL`, which
  is every wallet until `mix aurora_meter.credits.migrate_lots` runs) has no
  lots at all, and every function here answers `[]` or `nil` for it. That is
  the honest answer rather than a synthesised one: the legacy ledger does not
  record which grant a spend came out of, so a lot list invented from it would
  be a guess presented as provenance.
  """

  import Ecto.Query

  alias AuroraMeter.Config
  alias AuroraMeter.Schema.CreditAllocation
  alias AuroraMeter.Schema.CreditLot
  alias AuroraMeter.Tenant

  @typedoc """
  One grant's worth of credit.

  `available + reserved + consumed + reversed + expired == amount`, always, and
  the database refuses a row where it does not. `seq` is the ordering key and
  `granted_at` is for display: a timestamp comes from a wall clock and orders
  nothing.
  """
  @type lot :: %{
          id: Ecto.UUID.t(),
          reference: String.t(),
          category: :paid | :promotional | :adjustment,
          amount: non_neg_integer(),
          available: non_neg_integer(),
          reserved: non_neg_integer(),
          consumed: non_neg_integer(),
          reversed: non_neg_integer(),
          expired: non_neg_integer(),
          state: :open | :exhausted | :expired | :reversed,
          granted_at: DateTime.t(),
          expires_at: DateTime.t() | nil,
          grant_transaction_id: Ecto.UUID.t(),
          seq: integer(),
          source: map()
        }

  @typedoc """
  One movement of value between two buckets of one lot.

  `from_bucket` and `to_bucket` are not redundant with `kind`: a `consume` can
  come out of `available` (a debit) or out of `reserved` (a settlement against
  its own hold), and a `reverse` out of any of three. Folding a lot's
  allocations back into its five quantities needs the source (finding X249).
  """
  @type allocation :: %{
          id: Ecto.UUID.t(),
          lot_id: Ecto.UUID.t(),
          transaction_id: Ecto.UUID.t(),
          kind: CreditAllocation.kind(),
          from_bucket: CreditAllocation.bucket(),
          to_bucket: CreditAllocation.bucket(),
          amount: pos_integer(),
          seq: integer(),
          inserted_at: DateTime.t()
        }

  @default_limit 100
  @max_limit 500

  # The `source` keys `for_source/2` can match on. Deliberately a closed list:
  # `source` is free-form jsonb, and a matcher that accepted any key would let a
  # caller ask a question the index cannot answer and get a sequential scan of
  # every lot in the installation, or worse, ask a question with a typo in it
  # and be told "no lots" rather than "no such key".
  @source_keys [:payment_intent_id, :recurrence_key]

  @doc """
  `tenant`'s lots, in spend order.

  Options:

    * `:states`: which lot states to include. Default `[:open]`; `:all` for
      every state; or a list drawn from `#{inspect(CreditLot.states())}`.
    * `:categories`: restrict to these categories, from
      `#{inspect(CreditLot.categories())}`. Every category by default.
    * `:limit`: default #{@default_limit}, capped at #{@max_limit}.
    * `:order`: `:spend` (default) or `:granted_at`.
    * `:cursor`: the last lot of the previous page (the map this function
      returned, or its id). Paging never skips a lot and never returns one
      twice, because both orders end in the ordering key, which is unique.

  ## Examples

      AuroraMeter.Credits.Lots.list(org)
      #=> [%{reference: "promo:welcome", category: :promotional, available: 5_000_000, ...}]

      AuroraMeter.Credits.Lots.list(org, states: :all, categories: [:paid])

  """
  @spec list(term(), keyword()) :: [lot()]
  def list(tenant, opts \\ []) when is_list(opts) do
    tenant_key = Tenant.to_key(tenant)
    order = order(opts)

    from(l in CreditLot, where: l.tenant_key == ^tenant_key)
    |> filter_states(Keyword.get(opts, :states, [:open]))
    |> filter_categories(Keyword.get(opts, :categories))
    |> order_lots(order)
    |> page_lots(order, cursor_lot(tenant_key, Keyword.get(opts, :cursor)))
    |> limit(^limit(opts))
    |> Config.repo().all()
    |> Enum.map(&to_lot/1)
  end

  @doc """
  One lot of `tenant`'s, by lot id or by the reference of the grant that created
  it, or `nil`.

  The reference form is the one support has: a payment id, an invoice number,
  whatever the host passed as `:reference` to `AuroraMeter.Credits.grant/3`. A
  reference is unique per kind across the ledger, so it names at most one grant
  and therefore at most one lot.

  ## Examples

      AuroraMeter.Credits.Lots.get(org, "stripe:pi_123")
      AuroraMeter.Credits.Lots.get(org, "0b5f...uuid...")

  """
  @spec get(term(), Ecto.UUID.t() | String.t()) :: lot() | nil
  def get(tenant, id_or_reference) when is_binary(id_or_reference) do
    tenant_key = Tenant.to_key(tenant)

    query =
      case Ecto.UUID.cast(id_or_reference) do
        {:ok, id} ->
          from(l in CreditLot,
            where:
              l.tenant_key == ^tenant_key and
                (l.id == ^id or l.reference == ^id_or_reference)
          )

        :error ->
          from(l in CreditLot,
            where: l.tenant_key == ^tenant_key and l.reference == ^id_or_reference
          )
      end

    case Config.repo().one(from(l in query, order_by: [asc: l.seq], limit: 1)) do
      nil -> nil
      lot -> to_lot(lot)
    end
  end

  @doc """
  `tenant`'s allocation trail, oldest first.

  Options:

    * `:lot_id`: only this lot's movements.
    * `:transaction_id`: only the movements one ledger entry caused.
    * `:reference`: only the movements the entry with this reference caused.
      Matches a reversal written under either kind, so a refund reads the same
      whether it was written before or after schema version 9.
    * `:limit`: default #{@default_limit}, capped at #{@max_limit}.
    * `:cursor`: the last allocation of the previous page, or its id.

  ## Examples

      AuroraMeter.Credits.Lots.allocations(org, lot_id: lot.id)
      #=> [%{kind: :reserve, from_bucket: :available, to_bucket: :reserved, amount: 500_000, ...}]

  """
  @spec allocations(term(), keyword()) :: [allocation()]
  def allocations(tenant, opts \\ []) when is_list(opts) do
    tenant_key = Tenant.to_key(tenant)

    from(a in CreditAllocation, where: a.tenant_key == ^tenant_key)
    |> filter_lot(Keyword.get(opts, :lot_id))
    |> filter_transaction(Keyword.get(opts, :transaction_id))
    |> filter_reference(tenant_key, Keyword.get(opts, :reference))
    |> allocations_after(cursor_allocation(tenant_key, Keyword.get(opts, :cursor)))
    |> order_by([a], asc: a.seq)
    |> limit(^limit(opts))
    |> Config.repo().all()
    |> Enum.map(&to_allocation/1)
  end

  @doc """
  The lots whose `source` matches every key of `match`, in spend order.

  This is how a refund finds the credit a payment bought. `AuroraMeter.Credits`
  stamps `:source` from `grant/3` onto the lot the grant creates, so a host that
  passed `source: %{payment_intent_id: "pi_123"}` can ask for exactly those
  lots back and nothing else.

  Only `#{inspect(@source_keys)}` are supported in this release, and any other
  key raises `ArgumentError`. Silently returning everything for a key the
  matcher does not understand would turn a typo into a refund against the wrong
  customer's credit.

  ## Examples

      AuroraMeter.Credits.Lots.for_source(org, %{payment_intent_id: "pi_123"})
      #=> [%{reference: "stripe:pi_123", category: :paid, ...}]

  """
  @spec for_source(term(), map()) :: [lot()]
  def for_source(tenant, match) when is_map(match) and map_size(match) > 0 do
    tenant_key = Tenant.to_key(tenant)
    pairs = Enum.map(match, &source_pair/1)

    Enum.reduce(
      pairs,
      from(l in CreditLot, where: l.tenant_key == ^tenant_key),
      fn {key, value}, query ->
        where(query, [l], fragment("? ->> ? = ?", l.source, ^key, ^value))
      end
    )
    |> order_lots(:spend)
    |> limit(^@max_limit)
    |> Config.repo().all()
    |> Enum.map(&to_lot/1)
  end

  def for_source(_tenant, match) do
    raise ArgumentError,
          "for_source/2 needs at least one of #{inspect(@source_keys)} to match on, got: " <>
            inspect(match)
  end

  @spec source_pair({atom() | String.t(), term()}) :: {String.t(), String.t()}
  defp source_pair({key, value}) when is_binary(value) do
    atom = if is_atom(key), do: key, else: safe_atom(key)

    if atom in @source_keys do
      {Atom.to_string(atom), value}
    else
      raise ArgumentError,
            "for_source/2 supports #{inspect(@source_keys)} in this release, got: " <>
              "#{inspect(key)}. A `source` key the matcher does not understand would match " <>
              "every lot, and a refund against every lot is not a near miss."
    end
  end

  defp source_pair({key, value}) do
    raise ArgumentError,
          "for_source/2 matches string values, got #{inspect(value)} for #{inspect(key)}"
  end

  # `to_existing_atom` and not `to_atom`: a caller string that is not already one
  # of the supported keys must reach the message above rather than create an
  # atom, which is not garbage collected.
  defp safe_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> :__unsupported__
  end

  # -- query building ---------------------------------------------------------

  defp order(opts) do
    case Keyword.get(opts, :order, :spend) do
      order when order in [:spend, :granted_at] -> order
      other -> raise ArgumentError, ":order must be :spend or :granted_at, got: #{inspect(other)}"
    end
  end

  defp limit(opts) do
    case Keyword.get(opts, :limit, @default_limit) do
      limit when is_integer(limit) and limit > 0 -> min(limit, @max_limit)
      other -> raise ArgumentError, ":limit must be a positive integer, got: #{inspect(other)}"
    end
  end

  defp filter_states(query, :all), do: query

  defp filter_states(query, states) when is_list(states) do
    case Enum.reject(states, &(&1 in CreditLot.states())) do
      [] ->
        where(query, [l], l.state in ^states)

      bad ->
        raise ArgumentError,
              ":states must be :all or a list drawn from #{inspect(CreditLot.states())}, " <>
                "got: #{inspect(bad)}"
    end
  end

  defp filter_states(_query, other),
    do: raise(ArgumentError, ":states must be :all or a list, got: #{inspect(other)}")

  defp filter_categories(query, nil), do: query

  defp filter_categories(query, categories) when is_list(categories) do
    case Enum.reject(categories, &(&1 in CreditLot.categories())) do
      [] ->
        where(query, [l], l.category in ^categories)

      bad ->
        raise ArgumentError,
              ":categories must be drawn from #{inspect(CreditLot.categories())}, " <>
                "got: #{inspect(bad)}"
    end
  end

  # The spend order, expressed as the same four keys the engine sorts by. The
  # two `CASE` expressions are the two ranks that are not columns: promotional
  # first, and a non-expiring lot last within its category.
  defp order_lots(query, :spend) do
    order_by(query, [l],
      asc: fragment("CASE WHEN ?::text = 'promotional' THEN 0 ELSE 1 END", l.category),
      asc: fragment("CASE WHEN ? IS NULL THEN 1 ELSE 0 END", l.expires_at),
      asc: l.expires_at,
      asc: l.granted_at,
      asc: l.seq
    )
  end

  defp order_lots(query, :granted_at),
    do: order_by(query, [l], asc: l.granted_at, asc: l.seq)

  # Both orders end in `seq`, which is unique, so the keyset is total: a page
  # boundary cannot skip a lot or return one twice however many lots share a
  # `granted_at` or an `expires_at`.
  defp page_lots(query, _order, nil), do: query

  defp page_lots(query, :granted_at, lot) do
    where(
      query,
      [l],
      l.granted_at > ^lot.granted_at or (l.granted_at == ^lot.granted_at and l.seq > ^lot.seq)
    )
  end

  defp page_lots(query, :spend, lot) do
    where(
      query,
      [l],
      fragment(
        """
        (CASE WHEN ?::text = 'promotional' THEN 0 ELSE 1 END,
         CASE WHEN ? IS NULL THEN 1 ELSE 0 END,
         coalesce(?, '0001-01-01 00:00:00'::timestamp), ?, ?)
        > (?, ?, coalesce(?, '0001-01-01 00:00:00'::timestamp), ?, ?)
        """,
        l.category,
        l.expires_at,
        l.expires_at,
        l.granted_at,
        l.seq,
        ^category_rank(lot.category),
        ^expiry_rank(lot.expires_at),
        ^lot.expires_at,
        ^lot.granted_at,
        ^lot.seq
      )
    )
  end

  defp category_rank(:promotional), do: 0
  defp category_rank(_other), do: 1

  defp expiry_rank(nil), do: 1
  defp expiry_rank(_expires_at), do: 0

  defp cursor_lot(_tenant_key, nil), do: nil

  defp cursor_lot(_tenant_key, %{seq: seq, granted_at: granted_at} = lot)
       when is_integer(seq) and not is_nil(granted_at),
       do: lot

  defp cursor_lot(tenant_key, id) when is_binary(id) do
    case get(tenant_key, id) do
      nil -> raise ArgumentError, ":cursor names a lot that does not exist: #{inspect(id)}"
      lot -> lot
    end
  end

  defp cursor_lot(_tenant_key, other),
    do:
      raise(
        ArgumentError,
        ":cursor must be a lot from list/2 or a lot id, got: #{inspect(other)}"
      )

  defp filter_lot(query, nil), do: query
  defp filter_lot(query, lot_id), do: where(query, [a], a.lot_id == ^lot_id)

  defp filter_transaction(query, nil), do: query
  defp filter_transaction(query, id), do: where(query, [a], a.transaction_id == ^id)

  defp filter_reference(query, _tenant_key, nil), do: query

  defp filter_reference(query, tenant_key, reference) do
    ids =
      from(t in AuroraMeter.Schema.CreditTransaction,
        where: t.tenant_key == ^tenant_key and t.reference == ^reference,
        select: t.id
      )

    where(query, [a], a.transaction_id in subquery(ids))
  end

  defp allocations_after(query, nil), do: query
  defp allocations_after(query, seq), do: where(query, [a], a.seq > ^seq)

  defp cursor_allocation(_tenant_key, nil), do: nil
  defp cursor_allocation(_tenant_key, %{seq: seq}) when is_integer(seq), do: seq

  defp cursor_allocation(tenant_key, id) when is_binary(id) do
    seq =
      Config.repo().one(
        from(a in CreditAllocation,
          where: a.tenant_key == ^tenant_key and a.id == ^id,
          select: a.seq
        )
      )

    seq ||
      raise ArgumentError, ":cursor names an allocation that does not exist: #{inspect(id)}"
  end

  # -- projection -------------------------------------------------------------

  defp to_lot(%CreditLot{} = lot) do
    %{
      id: lot.id,
      reference: lot.reference,
      category: lot.category,
      amount: lot.amount,
      available: lot.available,
      reserved: lot.reserved,
      consumed: lot.consumed,
      reversed: lot.reversed,
      expired: lot.expired,
      state: lot.state,
      granted_at: lot.granted_at,
      expires_at: lot.expires_at,
      grant_transaction_id: lot.grant_transaction_id,
      seq: lot.seq,
      source: lot.source
    }
  end

  defp to_allocation(%CreditAllocation{} = allocation) do
    %{
      id: allocation.id,
      lot_id: allocation.lot_id,
      transaction_id: allocation.transaction_id,
      kind: allocation.kind,
      from_bucket: allocation.from_bucket,
      to_bucket: allocation.to_bucket,
      amount: allocation.amount,
      seq: allocation.seq,
      inserted_at: allocation.inserted_at
    }
  end
end
