defmodule AuroraMeter.Credits.Promotions do
  @moduledoc false

  require Logger

  # Reconstruct attribution in transaction order. A grant can only pay for
  # spending after it was issued, even when it expires before an older grant.
  # Replaying amounts also supports entries written before promotional_after
  # was added to the ledger.
  @spec remaining(Enumerable.t(), Ecto.UUID.t()) :: non_neg_integer()
  def remaining(entries, grant_id) do
    {grants, _total} = Enum.reduce(entries, {%{}, 0}, &apply_entry/2)

    case Map.get(grants, grant_id) do
      nil -> 0
      grant -> grant.remaining
    end
  end

  defp apply_entry(%{kind: :grant, category: :promotional} = entry, {grants, total}) do
    added = min(entry.amount, max(entry.balance_after - total, 0))

    grant = %{
      remaining: added,
      expires_at: entry.expires_at,
      inserted_at: entry.inserted_at,
      id: entry.id
    }

    {Map.put(grants, entry.id, grant), total + added}
  end

  defp apply_entry(%{amount: amount} = entry, {grants, total}) when amount < 0 do
    after_total =
      if entry.category == :reversal,
        do: min(total, max(entry.balance_after, 0)),
        else: max(total + amount, 0)

    consumed = total - after_total
    grant_id = if entry.kind == :expire, do: entry.metadata["grant_id"]
    {consume(grants, consumed, grant_id), after_total}
  end

  defp apply_entry(_entry, state), do: state

  # An `:expire` entry names the grant it consumed, and folding it needs that
  # grant to have been folded already. `Map.update!/3` raised `KeyError` when it
  # had not been, which was reachable because the ledger ordered this stream by
  # a wall clock (X213: 43 expiries instead of 50 in one run). Ordering by `seq`
  # closes that for every row written from schema version 9 on.
  #
  # It does not close it for a row written **before** version 9. Adding an
  # identity column rewrites the table and numbers the rows in the physical
  # order it reads them, and a row that was updated in place (a closed hold, a
  # stamped grant) is wherever its update put it (finding X244). So the fold
  # stays total: an expire entry whose grant is not in the map yet is
  # attributed by the ordinary soonest-expiry rule, which is what an untagged
  # spend of the same size would do, and it says so once rather than silently.
  defp consume(grants, amount, grant_id) when is_binary(grant_id) do
    case Map.fetch(grants, grant_id) do
      {:ok, grant} ->
        Map.put(grants, grant_id, %{grant | remaining: max(grant.remaining - amount, 0)})

      :error ->
        Logger.warning(
          "AuroraMeter.Credits.Promotions: an expire entry for grant #{inspect(grant_id)} was " <>
            "folded before the grant itself, which means this wallet holds rows whose `seq` " <>
            "is not their insertion order (pre-version-9 rows, finding X244). Attributing it " <>
            "by the ordinary spend order instead."
        )

        consume(grants, amount, nil)
    end
  end

  defp consume(grants, amount, nil) do
    {updated, _left} =
      grants
      |> Map.values()
      |> Enum.sort_by(
        &{expiry_key(&1.expires_at), DateTime.to_unix(&1.inserted_at, :microsecond), &1.id}
      )
      |> Enum.reduce({grants, amount}, fn grant, {acc, left} ->
        taken = min(grant.remaining, left)
        {Map.put(acc, grant.id, %{grant | remaining: grant.remaining - taken}), left - taken}
      end)

    updated
  end

  defp expiry_key(nil), do: {1, 0}
  defp expiry_key(datetime), do: {0, DateTime.to_unix(datetime)}
end
