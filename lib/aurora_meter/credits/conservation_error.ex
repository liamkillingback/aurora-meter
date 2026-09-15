defmodule AuroraMeter.Credits.ConservationError do
  @moduledoc """
  Raised when a wallet's balance row and its credit lots disagree.

  Every ledger write on a wallet that has been cut over to lots ends by
  comparing the row it just wrote against a `SUM` over that wallet's lots:

      balance     = sum(available) + sum(reserved) - debt
      held        = sum(reserved)
      promotional = sum(available + reserved) over promotional lots
      expired     = sum(expired)

  When they differ, this is raised rather than returned. A `with` chain can
  swallow an error tuple, and a financial invariant breach is the one thing that
  must never be swallowed: the raise aborts the transaction, so the write that
  would have been built on a wrong projection is not committed and the wallet is
  left exactly as it was.

  **Catching this and continuing is never correct.** The wallet is out of
  service for writes until a human has looked at it, which is the intended
  trade: a refused write is recoverable and a wrong balance is not. Reads keep
  working, so the lots and the ledger can both be inspected. Before raising, the
  ledger emits `[:aurora_meter, :credits, :conservation_error]` with the four
  deltas, so an alert fires on the first occurrence rather than on the first
  complaint.
  """

  @type t :: %__MODULE__{
          tenant_key: String.t(),
          operation: atom(),
          reference: String.t() | nil,
          deltas: %{atom() => integer()},
          expected: %{atom() => integer()},
          actual: %{atom() => integer()},
          message: String.t()
        }

  defexception [:tenant_key, :operation, :reference, :deltas, :expected, :actual, :message]

  @impl true
  @spec exception(keyword()) :: t()
  def exception(opts) do
    tenant_key = Keyword.fetch!(opts, :tenant_key)
    operation = Keyword.fetch!(opts, :operation)
    expected = Keyword.fetch!(opts, :expected)
    actual = Keyword.fetch!(opts, :actual)
    deltas = Keyword.fetch!(opts, :deltas)

    %__MODULE__{
      tenant_key: tenant_key,
      operation: operation,
      reference: Keyword.get(opts, :reference),
      deltas: deltas,
      expected: expected,
      actual: actual,
      message: build_message(tenant_key, operation, expected, actual, deltas)
    }
  end

  @spec build_message(String.t(), atom(), map(), map(), map()) :: String.t()
  defp build_message(tenant_key, operation, expected, actual, deltas) do
    "Aurora Meter credit conservation failed for tenant #{inspect(tenant_key)} during " <>
      "#{operation}: the balance row and the wallet's credit lots disagree.\n\n" <>
      "  balance row : #{inspect(actual)}\n" <>
      "  lots say    : #{inspect(expected)}\n" <>
      "  difference  : #{inspect(deltas)}\n\n" <>
      "Nothing was written: the transaction has been rolled back and the wallet is " <>
      "unchanged. It will refuse every further write until the disagreement is " <>
      "understood, which is deliberate. Reads still work, so the lots, the allocations " <>
      "and the ledger can all be inspected. Do not rescue this and continue."
  end
end
