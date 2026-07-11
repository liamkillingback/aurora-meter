defmodule AuroraMeter do
  @moduledoc """
  Aurora Meter — real-time usage metering, plan entitlements, and Stripe-ready
  billing primitives for Phoenix.

  Count, gate, and bill on the BEAM: increments hit an in-memory ETS counter
  (microseconds, no database on the hot path), a flusher persists snapshots to
  Postgres on an interval, and a broadcaster fans live values out over
  `Phoenix.PubSub`.

  This module is the Phase 0 scaffold. The public API — `track/4`, `check/2`,
  `with_quota/4`, `usage/2`, `remaining/2`, `subscribe/2` — is implemented in the
  phases described in `plan.md`. See `AGENTS.md` for the build contract.
  """

  @version Mix.Project.config()[:version]

  @doc """
  Returns the Aurora Meter version.

  ## Examples

      iex> is_binary(AuroraMeter.version())
      true

  """
  @spec version() :: String.t()
  def version, do: @version
end
