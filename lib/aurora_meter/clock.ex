defmodule AuroraMeter.Clock do
  @moduledoc """
  The single source of "now" for Aurora Meter.

  Every instant and every date in `lib/` comes from here, so a test can freeze
  time and so the library never depends on a primitive that can go backwards.
  The module configured under `clock:` (default `AuroraMeter.Clock.System`)
  implements the four callbacks below; hosts that want to freeze time in their
  own tests use `AuroraMeter.Test.with_clock/2`.

  ## Four questions, four readings

  | Question | Callback | Promise |
  |---|---|---|
  | What period is this? What do I display? What goes in `inserted_at`? | `now/0` | Wall-clock shaped and cheap. **It promises nothing about monotonicity and may step backwards.** |
  | What UTC day is this? | `today/0` | The date of `now/0`, never a second clock read. |
  | How long has this *in-memory* thing taken? (a cache TTL, a timeout, a span inside one process) | `monotonic_ms/0` | Strictly monotone within a node. Never persisted, never compared across nodes. |
  | Has enough time passed since something *persisted*? | `db_now/0` | The one clock every node in a cluster shares. Costs a round trip, so it is never on the `AuroraMeter.track/4` path. |

  ## The rule

  **Stamp and compare with the same clock, and for anything persisted that clock
  is the database's.**

  A decision that compares "now" against a timestamp read out of a row takes
  `db_now/0`, *and* that row's timestamp must itself have been stamped by the
  database, with a `fragment("clock_timestamp()")` or a column default. The
  defect is comparing a stamp from one clock against a reading from another; the
  size of any single clock error is not the point.

  Two things this does **not** claim. `db_now/0` does not make the database's
  clock perfect: that host's clock can be corrected too. What it removes is the
  skew *between two clocks*, and it leaves a single, operationally managed clock
  in its place. And ordering never takes a clock at all: it takes a sequence
  number. See `docs/periods.md`.

  ## Contract for an implementation

  - `now/0` returns a `DateTime` in `Etc/UTC` with microsecond precision. It is
    on the `AuroraMeter.track/4` path, so it must be pure and cheap.
  - `today/0` returns the `Date` of that same instant in UTC. Derive it from
    `now/0`; reading a second clock opens a window where an increment at
    midnight lands in the period of one day and the bucket of another.
  - `monotonic_ms/0` returns an integer in milliseconds from an arbitrary
    origin. Only differences between two readings are meaningful.
  - `db_now/0` returns a `DateTime` in `Etc/UTC` from the database the host
    configured. It may be slow and it may raise; no hot path calls it.
  """

  @doc "The current instant, in `Etc/UTC` with microsecond precision."
  @callback now() :: DateTime.t()

  @doc "The UTC date of `c:now/0`."
  @callback today() :: Date.t()

  @doc "A strictly monotonic millisecond reading, for in-memory elapsed spans only."
  @callback monotonic_ms() :: integer()

  @doc "The database's current instant: the one clock every node shares."
  @callback db_now() :: DateTime.t()

  @doc """
  The current instant from the configured clock.

  ## Examples

      iex> AuroraMeter.Clock.now().time_zone
      "Etc/UTC"

  """
  @spec now() :: DateTime.t()
  def now, do: AuroraMeter.Config.clock().now()

  @doc """
  The current UTC date from the configured clock.

  ## Examples

      iex> match?(%Date{}, AuroraMeter.Clock.today())
      true

  """
  @spec today() :: Date.t()
  def today, do: AuroraMeter.Config.clock().today()

  @doc """
  A monotonic millisecond reading from the configured clock.

  Use it for an elapsed span that begins and ends inside one node's memory.
  Never persist it and never compare it across nodes.

  ## Examples

      iex> is_integer(AuroraMeter.Clock.monotonic_ms())
      true

  """
  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: AuroraMeter.Config.clock().monotonic_ms()

  @doc false
  @spec monotonic_native() :: integer()
  # The raw monotonic reading, in `:native` units, and **deliberately not
  # through the configured clock**.
  #
  # It exists for `mix aurora_meter.bench`, which times operations that take
  # less than a microsecond: `monotonic_ms/0` is milliseconds and would report
  # every ETS increment as zero. It does not go through `Config.clock()`,
  # because a benchmark run under `AuroraMeter.Clock.Fixed` would then measure
  # a clock that does not move and report an infinite throughput, which is the
  # one number a benchmark must never be able to produce.
  #
  # It is here rather than in the bench because P07 is that every clock read
  # under `lib/` lives in this file, and that rule is worth more than the
  # convenience of an inline `System.monotonic_time/0` elsewhere. It is a
  # reading and never a comparison: `AuroraMeter.Bench.Mode.time/1` subtracts
  # two of these inside one process, which is what a monotonic clock is for
  # (`open-findings.md` X100).
  def monotonic_native, do: System.monotonic_time()

  @doc """
  The database's current instant, from the configured clock.

  Use it for every comparison against a timestamp that came out of a row, and
  make sure that row's timestamp was stamped by the database too. It costs a
  round trip: never call it from `AuroraMeter.track/4`, `check/2`, `reserve/2,3`
  or `with_quota/3,4`.

  ## Examples

      iex> AuroraMeter.Clock.db_now().time_zone
      "Etc/UTC"

  """
  @spec db_now() :: DateTime.t()
  def db_now, do: AuroraMeter.Config.clock().db_now()
end

defmodule AuroraMeter.Clock.System do
  @moduledoc """
  The default clock, and the only value supported in production.

  ## `now/0` makes no monotonicity promise, and that is deliberate

  `now/0` reads `System.system_time/1` rather than `DateTime.utc_now/0`. The
  reason is **cost, not correctness**: about 31 ns against 323 ns, and
  `AuroraMeter.track/4` reads it on every increment.

  Neither is monotone, and there is no monotone wall clock to be had. Measured
  on the development host over 420 seconds under load, 337,900,054 samples of
  each reading: `DateTime.utc_now/0` and `System.os_time/1` each stepped
  backwards 13 times (largest 1.330921 s), and `System.system_time/1` stepped
  backwards 6 times and further (largest 2.647191 s) on an exact 60 second
  offset-resync cadence, which `multi_time_warp`, the OTP 29 default, licenses.
  `+C no_time_warp` removes it, but the host owns `+C` and this is a library, so
  a VM flag is a diagnosis and never a remedy. The full measurement, the six
  candidate bases and the decision are in
  `docs/evidence/v1/phase-02/02c-clock-choice.md`.

  So: **do not compare `now/0` against a persisted timestamp.** Use `db_now/0`,
  and stamp the row with the database too.

  `today/0` is the date of `now/0`, never a second clock read.

  ## `db_now/0`

  `SELECT clock_timestamp() AT TIME ZONE 'UTC'` through the configured repo.
  `clock_timestamp()` rather than `now()` because `now()` is the transaction's
  start time and would return the same instant for every call inside one
  transaction, which is exactly wrong for "has enough time passed".

  With no repo configured it raises an `ArgumentError` naming the `repo` key
  rather than falling back to a node clock: a silent fallback would reintroduce
  the two-clock comparison this exists to remove. The SQL is Postgres; a storage
  adapter for something else configures its own `clock` module.
  """

  @behaviour AuroraMeter.Clock

  @db_now_sql "SELECT clock_timestamp() AT TIME ZONE 'UTC'"

  @doc "The node's current instant. Cheap, wall-clock shaped, and not monotone."
  @impl AuroraMeter.Clock
  @spec now() :: DateTime.t()
  def now, do: DateTime.from_unix!(System.system_time(:microsecond), :microsecond)

  @doc "The UTC date of `now/0`, derived from the same reading."
  @impl AuroraMeter.Clock
  @spec today() :: Date.t()
  def today, do: DateTime.to_date(now())

  @doc "A monotone millisecond reading, for an in-memory elapsed span only."
  @impl AuroraMeter.Clock
  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  @doc """
  The database's current instant, from `clock_timestamp()` through the
  configured repo. Raises an `ArgumentError` naming the `repo` key when none is
  configured.
  """
  @impl AuroraMeter.Clock
  @spec db_now() :: DateTime.t()
  def db_now do
    %{rows: [[instant]]} = repo!().query!(@db_now_sql, [])
    to_utc(instant)
  end

  defp repo! do
    case Application.get_env(:aurora_meter, :repo) do
      nil ->
        raise ArgumentError,
              "AuroraMeter.Clock.db_now/0 needs a database: set config :aurora_meter, " <>
                "repo: MyApp.Repo. It reads the database's own clock on purpose, because a " <>
                "decision about a persisted timestamp must not compare it against a node clock."

      repo ->
        repo
    end
  end

  # `AT TIME ZONE 'UTC'` yields `timestamp without time zone`, which Postgrex
  # decodes as a NaiveDateTime. The DateTime clause is there so a driver that
  # decodes it otherwise is still handled rather than crashing on a match.
  defp to_utc(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp to_utc(%DateTime{} = instant), do: instant
end

defmodule AuroraMeter.Clock.Fixed do
  @moduledoc """
  A frozen clock for tests: one `Agent` holding one instant.

  It ships in `lib/` rather than `test/support/` because host test suites need
  it, exactly as `AuroraMeter.Test` does. Drive it through
  `AuroraMeter.Test.with_clock/2` and `AuroraMeter.Test.travel/1,2` rather than
  starting it by hand: the helper serialises against other configuration
  changes, restores the previous `clock:` value on the way out (including on a
  raise) and stops the agent.

  It is a single named agent, so it is global to the node: every test that
  installs it must be `async: false`.

  All four readings come from the one frozen instant, `db_now/0` included. That
  is the point of putting `db_now/0` on the behaviour rather than leaving it as
  a bare query helper: a decision that consults the database's clock is exactly
  as testable as one that consults the node's, and a test can drive a cooldown
  or a retry horizon across its boundary in both directions without waiting.

  `monotonic_ms/0` moves in step with the frozen instant: travelling forward by
  90 seconds moves it by exactly 90_000. It is an *offset* from the real
  monotonic reading taken when the agent started, not the frozen instant's epoch
  milliseconds, so it shares a number line with the real monotonic clock and a
  span measured across the end of a frozen block is still comparable with one
  measured outside it. A cache TTL, for example, does not come back with an
  expiry decades in the future.

  Because `db_now/0` is answered from the frozen instant, a test using this
  clock stops exercising the real query. `AuroraMeter.ClockTest` closes that gap
  deliberately with cases that call `AuroraMeter.Clock.System.db_now/0`.
  """

  use Agent

  @behaviour AuroraMeter.Clock

  @unset """
  AuroraMeter.Clock.Fixed is configured as the clock but no instant is set. \
  Wrap the test in AuroraMeter.Test.with_clock/2, which starts the agent, sets \
  the instant and restores the previous clock afterwards.\
  """

  @typedoc "Any unit `DateTime.add/3` accepts."
  @type unit :: System.time_unit() | :day | :hour | :minute

  @typep state :: %{
           instant: DateTime.t() | nil,
           origin: DateTime.t() | nil,
           base_ms: integer()
         }

  @doc """
  Starts the agent. `:instant` pins it immediately; without one every read
  raises until `set/1` is called.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    instant = opts |> Keyword.get(:instant) |> microsecond()

    Agent.start_link(
      fn ->
        %{instant: instant, origin: instant, base_ms: System.monotonic_time(:millisecond)}
      end,
      name: __MODULE__
    )
  end

  @doc "Pins the clock to `instant`."
  @spec set(DateTime.t()) :: :ok
  def set(%DateTime{} = instant) do
    ensure_running!()
    instant = microsecond(instant)

    Agent.update(__MODULE__, fn current ->
      %{current | instant: instant, origin: current.origin || instant}
    end)
  end

  @doc """
  Moves the pinned instant by `amount` of `unit` (negative moves it back, which
  is how a test reproduces a backwards step deliberately).
  """
  @spec advance(integer(), unit()) :: :ok
  def advance(amount, unit) when is_integer(amount) do
    set(DateTime.add(now(), amount, unit))
  end

  @doc "Stops the agent. Safe to call when it is not running."
  @spec stop() :: :ok
  def stop do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Agent.stop(pid)
    end
  end

  @doc "Whether the fixed clock agent is running."
  @spec running?() :: boolean()
  def running?, do: is_pid(Process.whereis(__MODULE__))

  @impl AuroraMeter.Clock
  @spec now() :: DateTime.t()
  def now, do: pinned(state().instant)

  @impl AuroraMeter.Clock
  @spec today() :: Date.t()
  def today, do: DateTime.to_date(now())

  @impl AuroraMeter.Clock
  @spec monotonic_ms() :: integer()
  def monotonic_ms do
    current = state()
    current.base_ms + DateTime.diff(pinned(current.instant), current.origin, :millisecond)
  end

  @impl AuroraMeter.Clock
  @spec db_now() :: DateTime.t()
  def db_now, do: now()

  @spec state() :: state()
  defp state do
    ensure_running!()
    Agent.get(__MODULE__, & &1)
  end

  defp ensure_running! do
    if not running?(), do: raise(RuntimeError, @unset)
    :ok
  end

  defp pinned(nil), do: raise(RuntimeError, @unset)
  defp pinned(%DateTime{} = instant), do: instant

  # The behaviour says `now/0` returns microsecond precision, and a fake that
  # breaks its own contract is worse than no fake: a test freezing
  # `~U[2026-05-01 12:00:00Z]` (precision `{0, 0}`) would otherwise hand a
  # `:utc_datetime_usec` column a value Ecto refuses, and the test would fail
  # for a reason that has nothing to do with what it was testing.
  defp microsecond(nil), do: nil

  defp microsecond(%DateTime{microsecond: {value, _precision}} = instant),
    do: %{instant | microsecond: {value, 6}}
end
