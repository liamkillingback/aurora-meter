defmodule AuroraMeter.Credits.Promotions do
  @moduledoc false

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

  defp consume(grants, amount, grant_id) when is_binary(grant_id) do
    Map.update!(grants, grant_id, &%{&1 | remaining: max(&1.remaining - amount, 0)})
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
