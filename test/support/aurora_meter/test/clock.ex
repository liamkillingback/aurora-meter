defmodule AuroraMeter.Test.Clock do
  @moduledoc """
  A settable test clock.

  TEMPORARY, AND OWNED BY BUILD UNIT 01b. **Build unit 02c deletes this module**
  and replaces it with `AuroraMeter.Clock.Fixed` behind the `clock:`
  configuration key (`architecture-map.md` section 3). Nothing may build a
  long-lived API on it: when 02c lands, every caller moves to the real seam.
  The dependency in `dependency-map.md` runs the other way round on purpose,
  because 01b ships in wave 1a and 02c in wave 2.

  `lib/` cannot consume it in phase 01, because `lib/` has no clock seam yet
  (`open-findings.md` C11) and 01b modifies no `lib/` file. Its use in phase 01
  is therefore test-side arithmetic: computing a period boundary, choosing
  `expires_at` values, and asserting ordering without waiting. Where a phase-01
  test needs the *library* to see a different instant, it passes one explicitly
  to the function that already takes one (`AuroraMeter.Credits.expire_due/1`,
  `AuroraMeter.Period.current/2`) and says so in a comment.
  """

  use Agent

  @doc false
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(_opts \\ []), do: Agent.start_link(fn -> nil end, name: __MODULE__)

  @doc "Pins the clock to `instant`."
  @spec set(DateTime.t()) :: :ok
  def set(%DateTime{} = instant), do: Agent.update(__MODULE__, fn _ -> instant end)

  @doc "Pins the clock to `instant` truncated to the second, the resolution the ledger stamps at."
  @spec freeze(DateTime.t()) :: :ok
  def freeze(%DateTime{} = instant), do: set(DateTime.truncate(instant, :second))

  @doc "Moves a pinned clock forward by whole `seconds` (negative moves it back)."
  @spec advance(integer()) :: :ok
  def advance(seconds) when is_integer(seconds) do
    Agent.update(__MODULE__, fn
      nil -> DateTime.add(DateTime.utc_now(), seconds, :second)
      instant -> DateTime.add(instant, seconds, :second)
    end)
  end

  @doc "Returns to the system clock."
  @spec unset() :: :ok
  def unset, do: Agent.update(__MODULE__, fn _ -> nil end)

  @doc "The pinned instant, or the system clock when none is set."
  @spec now() :: DateTime.t()
  def now, do: Agent.get(__MODULE__, & &1) || DateTime.utc_now()

  @doc "The pinned date, or today."
  @spec today() :: Date.t()
  def today, do: DateTime.to_date(now())
end
