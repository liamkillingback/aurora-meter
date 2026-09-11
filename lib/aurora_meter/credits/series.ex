defmodule AuroraMeter.Credits.Series do
  @moduledoc false
  # Read-only aggregation over `aurora_meter_credit_transactions` behind
  # `AuroraMeter.Credits.spend_history/2`, `spend_total/2` and `summary/1`.
  #
  # ADR: the bucketing is a `date_trunc` GROUP BY in Postgres — one round trip
  # for a year of data, and the existing index on `(tenant_key, inserted_at)`
  # already covers the range scan. The **zero-fill** is deliberately *not* in
  # SQL (no `generate_series` LEFT JOIN): a chart with holes is the bug this
  # module exists to prevent, and filling in Elixir over an explicit list of
  # buckets is impossible to get subtly wrong the way an outer join on a
  # generated series is.
  #
  # ADR: `:hold` and `:release` are excluded from every aggregate. They move
  # `held`, never `balance` — counting a hold would double-count the money its
  # settlement later charges, and a released hold would show as spend that
  # never happened.
  #
  # ADR: the column is `utc_datetime_usec` (Postgres `timestamp without time
  # zone` holding UTC), so `date_trunc` on it *is* a UTC truncation. No time
  # zone conversion is applied anywhere; buckets are UTC by construction.

  import Ecto.Query

  alias AuroraMeter.Config
  alias AuroraMeter.Schema.CreditTransaction

  @spend_kinds [:settle, :debit, :expire]
  @grant_kinds [:grant]
  @excluded_kinds [:hold, :release]

  @typep point :: %{
           date: Date.t(),
           spent: non_neg_integer(),
           granted: non_neg_integer(),
           net: integer(),
           balance_after: integer() | nil
         }

  @typep totals :: %{spent: non_neg_integer(), granted: non_neg_integer(), net: integer()}

  @doc "The kinds that move money out of the balance: the default for `:kinds`."
  @spec spend_kinds() :: [CreditTransaction.kind()]
  def spend_kinds, do: @spend_kinds

  @doc "Resolves `:days` / `:from` / `:to` into an inclusive `{from, to}` UTC date range."
  @spec range(keyword()) :: {Date.t(), Date.t()}
  def range(opts) do
    to = Keyword.get(opts, :to, Date.utc_today())
    days = Keyword.get(opts, :days, 30)
    from = Keyword.get(opts, :from, Date.add(to, -(days - 1)))

    if Date.compare(from, to) == :gt do
      raise ArgumentError, "spend range :from (#{from}) is after :to (#{to})"
    end

    {from, to}
  end

  @doc "The spend kinds for this call, rejecting the kinds that move no money."
  @spec kinds(keyword()) :: [CreditTransaction.kind()]
  def kinds(opts) do
    kinds = Keyword.get(opts, :kinds, @spend_kinds)

    unless is_list(kinds) do
      raise ArgumentError, ":kinds must be a list of transaction kinds, got: #{inspect(kinds)}"
    end

    case Enum.filter(kinds, &(&1 in @excluded_kinds)) do
      [] ->
        kinds

      bad ->
        raise ArgumentError,
              ":kinds cannot include #{inspect(bad)} — holds and releases move `held`, not " <>
                "`balance`, so they are never spend"
    end
  end

  @doc "The bucket option: `:day` (default) or `:month`."
  @spec bucket(keyword()) :: :day | :month
  def bucket(opts) do
    case Keyword.get(opts, :bucket, :day) do
      bucket when bucket in [:day, :month] -> bucket
      other -> raise ArgumentError, ":bucket must be :day or :month, got: #{inspect(other)}"
    end
  end

  @doc """
  Zero-filled, oldest-first buckets over the inclusive date range: one entry per
  bucket whether or not the ledger has anything in it.
  """
  @spec history(String.t(), Date.t(), Date.t(), :day | :month, [CreditTransaction.kind()]) ::
          [point()]
  def history(tenant_key, from, to, bucket, spend_kinds) do
    rows =
      tenant_key
      |> bucketed_query(from, to, bucket, spend_kinds)
      |> Config.repo().all()
      |> Map.new(fn row ->
        {row.date,
         %{
           date: row.date,
           spent: row.spent,
           granted: row.granted,
           net: row.granted - row.spent,
           balance_after: row.balance_after
         }}
      end)

    Enum.map(buckets(from, to, bucket), fn date ->
      Map.get(rows, date, %{date: date, spent: 0, granted: 0, net: 0, balance_after: nil})
    end)
  end

  @doc "The totals over the whole inclusive date range, with no bucketing."
  @spec total(String.t(), Date.t(), Date.t(), [CreditTransaction.kind()]) :: totals()
  def total(tenant_key, from, to, spend_kinds) do
    sum_between(tenant_key, start_of(from), start_of(Date.add(to, 1)), spend_kinds)
  end

  @doc "The totals over an arbitrary half-open `[from, to)` datetime window."
  @spec sum_between(String.t(), DateTime.t(), DateTime.t(), [CreditTransaction.kind()]) ::
          totals()
  def sum_between(tenant_key, %DateTime{} = from, %DateTime{} = to, spend_kinds) do
    query =
      from(t in CreditTransaction,
        where: t.tenant_key == ^tenant_key,
        where: t.inserted_at >= ^from and t.inserted_at < ^to,
        where: t.kind in ^(spend_kinds ++ @grant_kinds),
        select: %{
          spent:
            type(
              sum(fragment("CASE WHEN ? THEN -? ELSE 0 END", t.kind in ^spend_kinds, t.amount)),
              :integer
            ),
          granted:
            type(
              sum(fragment("CASE WHEN ? THEN ? ELSE 0 END", t.kind in ^@grant_kinds, t.amount)),
              :integer
            )
        }
      )

    case Config.repo().one(query) do
      %{spent: spent, granted: granted} when is_integer(spent) and is_integer(granted) ->
        %{spent: spent, granted: granted, net: granted - spent}

      _empty_window ->
        %{spent: 0, granted: 0, net: 0}
    end
  end

  @spec bucketed_query(String.t(), Date.t(), Date.t(), :day | :month, [
          CreditTransaction.kind()
        ]) :: Ecto.Query.t()
  defp bucketed_query(tenant_key, from, to, bucket, spend_kinds) do
    unit = Atom.to_string(bucket)
    from_dt = start_of(from)
    to_dt = start_of(Date.add(to, 1))

    from(t in CreditTransaction,
      where: t.tenant_key == ^tenant_key,
      where: t.inserted_at >= ^from_dt and t.inserted_at < ^to_dt,
      where: t.kind in ^(spend_kinds ++ @grant_kinds),
      # `GROUP BY 1` (the first select item) rather than repeating the
      # expression: repeating it would emit a *different* parameter placeholder
      # for the unit, and Postgres matches GROUP BY expressions syntactically,
      # so it would reject the query as ungrouped.
      group_by: fragment("1"),
      select: %{
        date: type(fragment("date_trunc(?::text, ?)::date", ^unit, t.inserted_at), :date),
        spent:
          type(
            sum(fragment("CASE WHEN ? THEN -? ELSE 0 END", t.kind in ^spend_kinds, t.amount)),
            :integer
          ),
        granted:
          type(
            sum(fragment("CASE WHEN ? THEN ? ELSE 0 END", t.kind in ^@grant_kinds, t.amount)),
            :integer
          ),
        # The balance after the newest entry in the bucket; `id` breaks the tie
        # if two entries ever share a microsecond.
        balance_after:
          type(
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              t.balance_after,
              t.inserted_at,
              t.id
            ),
            :integer
          )
      }
    )
  end

  @spec buckets(Date.t(), Date.t(), :day | :month) :: [Date.t()]
  defp buckets(from, to, :day), do: Enum.to_list(Date.range(from, to))

  defp buckets(from, to, :month),
    do: months(Date.beginning_of_month(from), Date.beginning_of_month(to), [])

  @spec months(Date.t(), Date.t(), [Date.t()]) :: [Date.t()]
  defp months(current, last, acc) do
    if Date.compare(current, last) == :gt do
      Enum.reverse(acc)
    else
      months(current |> Date.end_of_month() |> Date.add(1), last, [current | acc])
    end
  end

  @spec start_of(Date.t()) :: DateTime.t()
  defp start_of(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
end
