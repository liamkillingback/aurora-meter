defmodule AuroraMeter.Test.Faults do
  @moduledoc """
  Deterministic fault injection for the maintainer suite (build unit 01b).

  A fault is armed by a test process against one of seven named points, fires at
  most `:count` times, and is observable afterwards in a fired log. Nothing here
  ships: this module lives in `test/support` and is in neither package's Hex
  archive.

  ## Points

  `:before_commit`, `:after_commit_before_ack`, `:after_claim`,
  `:after_provider_accept`, `:before_ack_persist`, `:during_shutdown`,
  `:during_recovery`. Arming any other point raises and names the valid set.

  ## Actions

  | Action | Effect |
  |---|---|
  | `:raise` | raises `AuroraMeter.Test.Faults.Injected` carrying the point, the context and the label |
  | `:exit_kill_self` | `Process.exit(self(), :kill)`: untrappable death at the check |
  | `{:block_until, ref}` | messages the owner `{:aurora_fault_blocked, point, pid, ref}` then waits for `{:aurora_fault_release, ref}`, raising `AuroraMeter.Test.Faults.Timeout` if the release never arrives |
  | `{:delay, ms}` | `Process.sleep(ms)`, the only sanctioned sleep, for wall-clock horizons the clock seam cannot reach |

  `{:block_until, ref}` deliberately *raises* on a lost rendezvous rather than
  returning an error value. Its predecessor in Pro,
  `test/support/blocking_credit_client.ex`, returned `{:error, :test_timeout}`,
  which the code under test then classified as a provider failure: the test
  failed five seconds later somewhere unrelated. A raise fails at the
  rendezvous.

  ## Ownership

  `check/2` resolves the owner from `[self() | Process.get(:"$callers", [])]`,
  the same chain `Ecto.Adapters.SQL.Sandbox` uses, and takes the first entry in
  that chain carrying an armed, unconsumed, predicate-satisfied fault. `Task`,
  `Task.Supervisor` and `Task.async_stream` all set `$callers`; a bare
  `spawn/1` does not, and neither does a `GenServer.call/3`, which runs in the
  server. Both need `owner:` naming the pid that will do the checking
  (`owner: Process.whereis(AuroraMeter.Flusher)`), and `fired/1` and
  `assert_fired!/2` take the same option so the test can still see that it
  fired.

  The `:when` predicate is evaluated exactly once per check, in the *checking*
  process, and never again in the server. A scripted fault may therefore carry
  a side effect, provided the test guarantees a single checker.

  When the owner dies its faults are disarmed and its fired log dropped, so a
  killed test cannot leave an armed fault for the next module.

  ## Rule

  Every test that arms a fault asserts it fired (`assert_fired!/1`). A test that
  arms `:before_commit`, drifts off the call path and then passes because the
  fault never ran is indistinguishable from a real proof.
  """

  use GenServer

  @points [
    :before_commit,
    :after_commit_before_ack,
    :after_claim,
    :after_provider_accept,
    :before_ack_persist,
    :during_shutdown,
    :during_recovery
  ]

  @default_block_timeout 5_000

  @typedoc "A failure boundary a shim can reach."
  @type point ::
          :before_commit
          | :after_commit_before_ack
          | :after_claim
          | :after_provider_accept
          | :before_ack_persist
          | :during_shutdown
          | :during_recovery

  @typedoc "What firing does to the checking process."
  @type action :: :raise | :exit_kill_self | {:block_until, reference()} | {:delay, pos_integer()}

  # These two keep their names. The library's own exceptions all end in `Error`,
  # and from build unit 02b they outnumber these, so Credo's consistency check
  # now reads `Error` as the house style and reports the harness as the outlier.
  # Renaming them would rename two test descriptions that build unit 01b's
  # evidence tables quote verbatim, which is a worse trade than two comments:
  # these are fault fixtures raised inside a test, not part of the library's
  # error model.
  # credo:disable-for-next-line Credo.Check.Consistency.ExceptionNames
  defmodule Injected do
    @moduledoc "Raised by the `:raise` action. Carries the point, context and label."
    defexception [:point, :context, :label]

    @impl true
    def message(%{point: point, context: context, label: label}) do
      "injected fault at #{inspect(point)} (label: #{inspect(label)}) context: #{inspect(context)}"
    end
  end

  # credo:disable-for-next-line Credo.Check.Consistency.ExceptionNames
  defmodule Timeout do
    @moduledoc "Raised when a `{:block_until, ref}` release never arrives."
    defexception [:point, :ref, :owner, :blocked, :timeout]

    @impl true
    def message(%{point: point, ref: ref, owner: owner, blocked: blocked, timeout: timeout}) do
      "blocked fault at #{inspect(point)} was never released after #{timeout}ms: " <>
        "ref #{inspect(ref)}, owner #{inspect(owner)}, blocked pid #{inspect(blocked)}"
    end
  end

  @doc "The seven points, in the order the programme names them."
  @spec points() :: [point()]
  def points, do: @points

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Arms `point` with `action`.

  Options: `:owner` (default `self()`), `:count` (default `1`, `:infinity`
  allowed), `:when` (a one-arity predicate over the context map, default always
  true), `:label` (echoed into the fired log) and `:block_timeout` (default
  #{@default_block_timeout} ms, used only by `{:block_until, ref}`).

  Arming the same `{owner, point}` twice replaces the first arming.
  """
  @spec arm(point(), action(), keyword()) :: :ok
  def arm(point, action, opts \\ []) do
    validate_point!(point)
    validate_action!(action)

    entry = %{
      owner: Keyword.get(opts, :owner, self()),
      point: point,
      action: action,
      count: validate_count!(Keyword.get(opts, :count, 1)),
      when: Keyword.get(opts, :when, fn _ -> true end),
      label: Keyword.get(opts, :label),
      block_timeout: Keyword.get(opts, :block_timeout, @default_block_timeout)
    }

    GenServer.call(__MODULE__, {:arm, entry})
  end

  @doc "Disarms `point` for `opts[:owner]` (default `self()`)."
  @spec disarm(point(), keyword()) :: :ok
  def disarm(point, opts \\ []) do
    validate_point!(point)
    GenServer.call(__MODULE__, {:disarm, Keyword.get(opts, :owner, self()), point})
  end

  @doc """
  Disarms every fault armed by the calling process or by any process in its
  caller chain. The fired log is left alone, so `assert_fired!/1` still works
  afterwards.
  """
  @spec disarm_all() :: :ok
  def disarm_all, do: GenServer.call(__MODULE__, {:disarm_all, chain()})

  @doc """
  The shim call. Fires at most one armed fault for this point and caller chain.

  Returns `:ok` when nothing is armed, which is the overwhelmingly common case
  and costs one ETS lookup per owner in the chain.
  """
  @spec check(point(), map()) :: :ok
  def check(point, context \\ %{}) do
    validate_point!(point)

    case candidate(point, context) do
      nil ->
        :ok

      owner ->
        case GenServer.call(__MODULE__, {:claim, owner, point, context}) do
          :none -> :ok
          {:fire, action, label, timeout} -> fire(action, point, context, label, owner, timeout)
        end
    end
  end

  @doc """
  Every fault that fired for the calling process or its caller chain, oldest
  first, as `{point, context, fired_at}`. The context carries the `:action` and
  `:label` of the fault that fired alongside the shim's own keys.

  `opts[:owner]` widens the lookup to a pid outside the caller chain, for a
  fault armed against a `GenServer` (`owner: Process.whereis(Flusher)`).
  """
  @spec fired(keyword()) :: [{point(), map(), DateTime.t()}]
  def fired(opts \\ []), do: GenServer.call(__MODULE__, {:fired, owners(opts)})

  @doc """
  Asserts that `point` fired for this process (or its caller chain, or
  `opts[:owner]`).

  Raises `ExUnit.AssertionError` naming the points that did fire when it did
  not. This is the rule that makes an armed-but-unreached fault a failure
  rather than a silent pass.
  """
  @spec assert_fired!(point(), keyword()) :: :ok
  def assert_fired!(point, opts \\ []) do
    validate_point!(point)
    entries = fired(opts)

    if Enum.any?(entries, fn {fired_point, _, _} -> fired_point == point end) do
      :ok
    else
      raise ExUnit.AssertionError,
        message:
          "expected a fault at #{inspect(point)} to have fired, but it did not. " <>
            "Points that did fire: #{inspect(Enum.map(entries, &elem(&1, 0)))}"
    end
  end

  @doc """
  Drops the fired log for the calling process, its caller chain and
  `opts[:owner]`.

  Call it before arming against a long-lived process (a `GenServer` that
  outlives the test), so `assert_fired!/2` cannot pass on an entry an earlier
  test left behind.
  """
  @spec forget(keyword()) :: :ok
  def forget(opts \\ []), do: GenServer.call(__MODULE__, {:forget, owners(opts)})

  @doc "Releases a process blocked by `{:block_until, ref}`."
  @spec release(pid(), reference()) :: :ok
  def release(pid, ref) do
    send(pid, {:aurora_fault_release, ref})
    :ok
  end

  # -- server ----------------------------------------------------------------

  @impl true
  def init(_opts) do
    table = :ets.new(__MODULE__, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{table: table, fired: [], monitors: %{}}}
  end

  @impl true
  def handle_call({:arm, entry}, _from, state) do
    :ets.insert(
      state.table,
      {{entry.owner, entry.point}, entry.count, entry.action, entry.when, entry.label,
       entry.block_timeout}
    )

    {:reply, :ok, monitor(state, entry.owner)}
  end

  def handle_call({:disarm, owner, point}, _from, state) do
    :ets.delete(state.table, {owner, point})
    {:reply, :ok, state}
  end

  def handle_call({:disarm_all, owners}, _from, state) do
    for owner <- owners, point <- @points, do: :ets.delete(state.table, {owner, point})
    {:reply, :ok, state}
  end

  def handle_call({:claim, owner, point, context}, _from, state) do
    key = {owner, point}

    case :ets.lookup(state.table, key) do
      [{^key, count, action, _predicate, label, timeout}] ->
        claim(state, key, {count, action, label, timeout}, {owner, point, context})

      [] ->
        {:reply, :none, state}
    end
  end

  def handle_call({:forget, owners}, _from, state) do
    {:reply, :ok,
     %{state | fired: Enum.reject(state.fired, fn {owner, _, _, _} -> owner in owners end)}}
  end

  def handle_call({:fired, owners}, _from, state) do
    entries =
      state.fired
      |> Enum.filter(fn {fired_owner, _, _, _} -> fired_owner in owners end)
      |> Enum.map(fn {_, point, context, at} -> {point, context, at} end)
      |> Enum.reverse()

    {:reply, entries, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    for point <- @points, do: :ets.delete(state.table, {pid, point})

    {:noreply,
     %{
       state
       | fired: Enum.reject(state.fired, fn {owner, _, _, _} -> owner == pid end),
         monitors: Map.delete(state.monitors, pid)
     }}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp claim(state, _key, {0, _action, _label, _timeout}, _who), do: {:reply, :none, state}

  defp claim(state, key, {count, action, label, timeout}, {owner, point, context}) do
    if is_integer(count), do: :ets.update_counter(state.table, key, {2, -1, 0, 0})

    record =
      {owner, point, Map.merge(context, %{action: action, label: label}), DateTime.utc_now()}

    {:reply, {:fire, action, label, timeout}, %{state | fired: [record | state.fired]}}
  end

  defp monitor(state, owner) do
    if Map.has_key?(state.monitors, owner) do
      state
    else
      ref = Process.monitor(owner)
      %{state | monitors: Map.put(state.monitors, owner, ref)}
    end
  end

  # -- caller side -----------------------------------------------------------

  defp candidate(point, context) do
    Enum.find(chain(), fn owner ->
      case :ets.lookup(__MODULE__, {owner, point}) do
        [{_, count, _action, predicate, _label, _timeout}] ->
          count != 0 and predicate?(predicate, point, context)

        [] ->
          false
      end
    end)
  end

  # The predicate runs exactly once per check, here in the checking process,
  # never again in the server. A scripted fault may therefore have a side
  # effect, provided the test guarantees a single checker (two concurrent
  # checkers both evaluate it and only one wins the count).
  defp predicate?(predicate, point, context) do
    predicate.(context)
  rescue
    error ->
      reraise ArgumentError,
              [
                message:
                  "the :when predicate for #{inspect(point)} raised " <>
                    "#{inspect(error.__struct__)} on context #{inspect(context)}. Use Access " <>
                    "(&1[:key]) rather than &1.key: one point is checked by several shims and " <>
                    "the context keys differ."
              ],
              __STACKTRACE__
  end

  defp chain, do: [self() | Process.get(:"$callers", [])]

  defp owners(opts), do: Enum.uniq(chain() ++ List.wrap(Keyword.get(opts, :owner)))

  defp fire(:raise, point, context, label, _owner, _timeout) do
    raise Injected, point: point, context: context, label: label
  end

  defp fire(:exit_kill_self, _point, _context, _label, _owner, _timeout) do
    Process.exit(self(), :kill)
    :ok
  end

  defp fire({:block_until, ref}, point, _context, _label, owner, timeout) do
    send(owner, {:aurora_fault_blocked, point, self(), ref})

    receive do
      {:aurora_fault_release, ^ref} -> :ok
    after
      timeout ->
        raise Timeout, point: point, ref: ref, owner: owner, blocked: self(), timeout: timeout
    end
  end

  defp fire({:delay, ms}, _point, _context, _label, _owner, _timeout) do
    Process.sleep(ms)
    :ok
  end

  defp validate_point!(point) when point in @points, do: :ok

  defp validate_point!(point) do
    raise ArgumentError,
          "unknown fault point #{inspect(point)}; valid points are #{inspect(@points)}"
  end

  defp validate_action!(:raise), do: :ok
  defp validate_action!(:exit_kill_self), do: :ok
  defp validate_action!({:block_until, ref}) when is_reference(ref), do: :ok
  defp validate_action!({:delay, ms}) when is_integer(ms) and ms > 0, do: :ok

  defp validate_action!(action) do
    raise ArgumentError,
          "unknown fault action #{inspect(action)}; valid actions are :raise, " <>
            ":exit_kill_self, {:block_until, ref} and {:delay, ms}"
  end

  defp validate_count!(:infinity), do: :infinity
  defp validate_count!(count) when is_integer(count) and count > 0, do: count

  defp validate_count!(count) do
    raise ArgumentError, "count must be a positive integer or :infinity, got #{inspect(count)}"
  end
end
