defmodule AuroraMeter.ExporterCase.WrongExporters do
  @moduledoc """
  Eleven adapters, each wrong in exactly one way, so that every area of
  `AuroraMeter.ExporterCase` can be shown to reject something.

  A conformance suite that has never rejected anything is decoration
  (`open-findings.md` X125: a test whose subject is one layer can be satisfied
  by another, and the only way to know is to break the layer on purpose). These
  are the deliberate breakages, and `AuroraMeter.ExporterCaseSelfTest` asserts
  that the named assertion fails for each one.

  Each is a thin wrapper over `AuroraMeter.Exporter.Journal`, so the only
  difference between a wrong adapter and the reference one is the defect being
  demonstrated.

  Two of them are wrong only on a single-item call. That is not a contrivance
  to make the negative control surgical: it is the shape of the code this
  behaviour replaces, whose usage export only ever built single-entry lists, so
  a defect on that path was invisible to anything that looked at batches.
  """

  alias AuroraMeter.Exporter.Journal

  defmodule Dropping do
    @moduledoc false
    @behaviour AuroraMeter.Exporter

    @impl true
    def describe, do: Journal.describe()

    @impl true
    def deliver([_single], _context), do: []
    def deliver(items, context), do: Journal.deliver(items, context)
  end

  defmodule Inventing do
    @moduledoc false
    @behaviour AuroraMeter.Exporter

    @impl true
    def describe, do: Journal.describe()

    @impl true
    def deliver([single] = items, context) do
      Journal.deliver(items, context) ++ [{single.id <> "_ghost", :accepted}]
    end

    def deliver(items, context), do: Journal.deliver(items, context)
  end

  defmodule AnswersOk do
    @moduledoc false
    @behaviour AuroraMeter.Exporter

    @impl true
    def describe, do: Journal.describe()

    @impl true
    def deliver(items, context) do
      _ = Journal.deliver(items, context)
      :ok
    end
  end

  defmodule Mutating do
    @moduledoc false
    @behaviour AuroraMeter.Exporter

    @impl true
    def describe, do: Journal.describe()

    @impl true
    def deliver(items, context) do
      # Re-derives a payload field from live state between attempts, which is
      # precisely the retry that sends different bytes under one identity.
      Journal.deliver(
        Enum.map(items, fn item ->
          %{item | payload: Map.put(item.payload, "quantity", item.attempts + 1)}
        end),
        context
      )
    end
  end

  defmodule Swallowing do
    @moduledoc false
    @behaviour AuroraMeter.Exporter

    @impl true
    def describe, do: Journal.describe()

    @impl true
    def deliver(items, context) do
      Journal.deliver(items, context)
    rescue
      _exception -> Enum.map(items, &{&1.id, {:accepted, "swallowed"}})
    end
  end

  defmodule TerminalRateLimit do
    @moduledoc false
    @behaviour AuroraMeter.Exporter

    @impl true
    def describe, do: Journal.describe()

    @impl true
    def deliver(items, context) do
      Enum.map(Journal.deliver(items, context), fn
        {id, {:retry, _delay}} -> {id, {:rejected, :too_many_requests}}
        other -> other
      end)
    end
  end

  defmodule OptimisticUnknown do
    @moduledoc false
    @behaviour AuroraMeter.Exporter

    @impl true
    def describe, do: Journal.describe()

    @impl true
    def deliver(items, context) do
      Enum.map(Journal.deliver(items, context), fn {id, outcome} ->
        if AuroraMeter.Exporter.outcome?(outcome), do: {id, outcome}, else: {id, :accepted}
      end)
    end
  end

  defmodule OptimisticMalformed do
    @moduledoc false
    @behaviour AuroraMeter.Exporter

    @impl true
    def describe, do: Journal.describe()

    @impl true
    def deliver(items, context) do
      Enum.map(Journal.deliver(items, context), fn
        {id, {:ok, _body}} -> {id, :accepted}
        other -> other
      end)
    end
  end

  defmodule HaltsOnFirstProblem do
    @moduledoc false
    @behaviour AuroraMeter.Exporter

    @impl true
    def describe, do: Journal.describe()

    @impl true
    def deliver(items, context) do
      items
      |> Enum.reduce_while([], fn item, acc ->
        case Journal.deliver([item], context) do
          [{_id, :accepted}] = result -> {:cont, acc ++ result}
          [{_id, _other}] = result -> {:halt, acc ++ result}
        end
      end)
    end
  end

  defmodule BareRetry do
    @moduledoc false
    @behaviour AuroraMeter.Exporter

    @impl true
    def describe, do: Journal.describe()

    @impl true
    def deliver(items, context) do
      Enum.map(Journal.deliver(items, context), fn
        {id, {:retry, _delay}} -> {id, :retry}
        other -> other
      end)
    end
  end

  defmodule BadDescription do
    @moduledoc false
    @behaviour AuroraMeter.Exporter

    @impl true
    def describe, do: %{Journal.describe() | max_batch: 0}

    @impl true
    def deliver(items, context), do: Journal.deliver(items, context)
  end

  defmodule DriftingDescription do
    @moduledoc false
    @behaviour AuroraMeter.Exporter

    @impl true
    def describe do
      %{Journal.describe() | max_batch: System.unique_integer([:positive])}
    end

    @impl true
    def deliver(items, context), do: Journal.deliver(items, context)
  end

  defmodule Exiting do
    @moduledoc false
    @behaviour AuroraMeter.Exporter

    @impl true
    def describe, do: Journal.describe()

    @impl true
    def deliver(_items, _context), do: exit(:provider_gone)
  end

  defmodule Throwing do
    @moduledoc false
    @behaviour AuroraMeter.Exporter

    @impl true
    def describe, do: Journal.describe()

    @impl true
    def deliver(_items, _context), do: throw(:provider_gone)
  end
end

defmodule AuroraMeter.ExporterCase.JournalScript do
  @moduledoc """
  The translation between the suite's scenarios and what
  `AuroraMeter.Exporter.Journal` can be told to do, shared by every module in
  this file.
  """

  alias AuroraMeter.Exporter.Journal

  @doc "Scripts one scenario for `subject_ref`."
  @spec script(String.t(), term()) :: :ok | :unsupported
  def script(subject_ref, :rate_limited), do: Journal.script(subject_ref, {:retry, 30})
  def script(subject_ref, :malformed), do: Journal.script(subject_ref, {:ok, %{"s" => "???"}})
  def script(subject_ref, :unknown_status), do: Journal.script(subject_ref, :pending_review)
  def script(subject_ref, :raise), do: Journal.script(subject_ref, {:raise, "provider exploded"})
  def script(subject_ref, outcome), do: Journal.script(subject_ref, outcome)

  @doc "The payloads the journal recorded for `subject_ref`, oldest first."
  @spec sent(String.t()) :: [map()]
  def sent(subject_ref) do
    subject_ref |> Journal.deliveries_for() |> Enum.map(& &1.item.payload)
  end

  @doc """
  Stops a journal started by a setup, tolerating one that has already gone.

  **A teardown must not assert something it does not mean to assert.** This was
  `if Process.alive?(pid), do: Agent.stop(pid), else: :ok`, which is
  check-then-act, and the gap between the check and the call is reachable:

    * the journal is started with `start_link/1`, so it is **linked to the test
      process**;
    * `on_exit` callbacks run in `ExUnit.OnExitHandler`, a different process,
      **after** the test process has exited;
    * so the link is already tearing the journal down when the callback runs.
      `Process.alive?/1` can answer `true` and the `Agent.stop/1` a few
      microseconds later exit `:noproc`, which ExUnit reports as the **test**
      failing, in a teardown that had nothing to say about the test.

  It only appears under full-suite load, because that is when the two are slow
  enough to interleave. Seen once in build unit 06e's `mix check`
  (`AuroraMeter.ExporterCaseSelfTest` / `test coverage reporting the suite names
  every area it could not script`), never in five fixed-seed runs of the file on
  its own.

  **Catching the exit is the fix rather than widening the window**, because
  there is no window: nothing can die between a call and its own failure. What
  is still asserted is that there was a process to stop at all, which is the
  `is_pid/1` guard: a teardown handed `nil` still fails, as it should.

  The same shape is `open-findings.md` X260, in `AuroraMeter.Test.Kill`, and it
  needs a different fix there for a reason worth knowing: X260 loses the exit
  **reason**, which cannot be recovered after the fact, so its monitor has to be
  established before the worker can die rather than its error tolerated.
  """
  @spec stop(pid()) :: :ok
  def stop(pid) when is_pid(pid) do
    Agent.stop(pid)
  catch
    :exit, reason -> if gone?(reason), do: :ok, else: exit(reason)
  end

  # **"The journal is no longer there", in the shapes the VM actually states it
  # in**, both of which were measured rather than guessed
  # (`tmp/v1/06e-teardown-race.exs`, 5,000 rounds a run):
  #
  #   {:noproc, {GenServer, :stop, [pid, :normal, :infinity]}}
  #     the stop never reached a process at all;
  #
  #   {{:shutdown, {:sys, :terminate, [pid, :normal, :infinity]}},
  #    {GenServer, :stop, [pid, :normal, :infinity]}}
  #     the stop reached it while the link's `:shutdown` was already tearing it
  #     down, so `:gen.stop/3` reports the exit reason it observed rather than
  #     the one it asked for.
  #
  # The second is the one a first draft of this fix missed, because it catches
  # `:shutdown` as a **tuple** and not as an atom. Nothing else is tolerated: a
  # journal that times out, or that crashes on the way down, still fails the
  # teardown, which is what a teardown is for.
  defp gone?({reason, {GenServer, :stop, _args}}), do: gone?(reason)
  defp gone?({:shutdown, {:sys, :terminate, _args}}), do: true
  defp gone?(reason) when reason in [:noproc, :normal, :shutdown], do: true
  defp gone?(_reason), do: false
end

defmodule AuroraMeter.ExporterCaseJournalTest do
  @moduledoc """
  The reference exporter, put through the suite it ships with (build unit 04a).

  `require_scriptable: true`: the journal can be told to do every one of the
  scenarios, so anything it cannot exercise is a defect in this file rather than
  a limitation of the adapter.
  """
  use ExUnit.Case, async: false
  use AuroraMeter.ExporterCase, exporter: AuroraMeter.Exporter.Journal, require_scriptable: true

  alias AuroraMeter.Exporter.Journal
  alias AuroraMeter.ExporterCase.JournalScript

  defdelegate script(subject_ref, scenario), to: JournalScript
  defdelegate sent(subject_ref), to: JournalScript

  @doc false
  def setup_exporter(_config) do
    case Journal.start_link([]) do
      {:ok, pid} -> ExUnit.Callbacks.on_exit(fn -> JournalScript.stop(pid) end)
      {:error, {:already_started, _pid}} -> Journal.reset()
    end

    %{}
  end
end

defmodule AuroraMeter.ExporterCaseSelfTest do
  @moduledoc """
  Proof that the conformance suite rejects something (build unit 04a).

  X125's rule, applied to a suite rather than to a lock: defence in depth means
  a green test can be green for the wrong reason, and the only way to know an
  assertion works is to break what it checks and watch it fail. So every area of
  `AuroraMeter.ExporterCase` has an adapter here that violates exactly that
  area, and this file asserts the named assertion raises for it.

  The assertions are called directly rather than by running a nested ExUnit
  suite: a nested run would report its own failures as this run's, and the
  failure message is the thing being checked.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AuroraMeter.Exporter.Journal
  alias AuroraMeter.ExporterCase
  alias AuroraMeter.ExporterCase.JournalScript
  alias AuroraMeter.ExporterCase.WrongExporters

  setup do
    case Journal.start_link([]) do
      {:ok, pid} -> on_exit(fn -> JournalScript.stop(pid) end)
      {:error, {:already_started, _pid}} -> Journal.reset()
    end

    :ok
  end

  describe "the reference journal" do
    test "the case injects exactly the eleven named tests, and the journal module has them" do
      # The assertions below are called directly, so nothing else in this file
      # would notice a `describe` block deleted from the `using` macro. This
      # does: the names are the contract every adapter's report is read against.
      names =
        AuroraMeter.ExporterCaseJournalTest.__ex_unit__()
        |> Map.fetch!(:tests)
        |> Enum.map(& &1.name)
        |> Enum.map(&Atom.to_string/1)
        |> Enum.sort()

      assert names == [
               "test AuroraMeter.ExporterCase: coverage the suite names every area it could not script",
               "test AuroraMeter.ExporterCase: description E4 describe is constant across calls",
               "test AuroraMeter.ExporterCase: description E4 describe returns the documented shape, with a positive max_batch",
               "test AuroraMeter.ExporterCase: exceptions E3 a provider call that blows up is uncertain for every item in the call",
               "test AuroraMeter.ExporterCase: identity E1 delivers one outcome per item and no outcome for an id it was not given",
               "test AuroraMeter.ExporterCase: identity E5 redelivering one item does not change the payload the adapter sends",
               "test AuroraMeter.ExporterCase: malformed response E2 a malformed provider answer is uncertain, never accepted",
               "test AuroraMeter.ExporterCase: partial success E1 a batch where one member is accepted and one is retried returns both",
               "test AuroraMeter.ExporterCase: rate limiting E2 a rate-limit answer is a retry, never a rejection",
               "test AuroraMeter.ExporterCase: retry E2 a scripted retry outcome comes back as {:retry, delay} or {:retry, nil}",
               "test AuroraMeter.ExporterCase: unknown outcome E2 an unrecognised provider status is uncertain"
             ]
    end

    test "the reference journal passes every conformance area" do
      ctx = context(Journal)

      assert ExporterCase.assert_identity!(ctx) == :ok
      assert ExporterCase.assert_payload_identity!(ctx) == :ok
      assert ExporterCase.assert_retry!(ctx) == :ok
      assert ExporterCase.assert_partial_success!(ctx) == :ok
      assert ExporterCase.assert_malformed_response!(ctx) == :ok
      assert ExporterCase.assert_rate_limiting!(ctx) == :ok
      assert ExporterCase.assert_unknown_outcome!(ctx) == :ok
      assert ExporterCase.assert_exceptions!(ctx) == :ok
      assert ExporterCase.assert_description!(ctx) == :ok
      assert ExporterCase.assert_description_constant!(ctx) == :ok
      assert ExporterCase.assert_coverage!(ctx) == :ok
    end
  end

  describe "the suite rejects a wrong adapter" do
    test "an exporter that drops an item fails the identity area" do
      assert_fails(WrongExporters.Dropping, :assert_identity!, "uncertain")
    end

    test "an exporter that invents an item id fails the identity area" do
      assert_fails(WrongExporters.Inventing, :assert_identity!, "an id it was not given")
    end

    test "an exporter that answers :ok fails the identity area" do
      assert_fails(WrongExporters.AnswersOk, :assert_identity!, "must return a list")
    end

    test "an exporter that returns a different payload on the second call fails E5" do
      assert_fails(WrongExporters.Mutating, :assert_payload_identity!, "different bytes")
    end

    test "an exporter that swallows a provider blow-up fails the exception area" do
      assert_fails(WrongExporters.Swallowing, :assert_exceptions!, "blew up came back as")
    end

    test "an exporter that makes a rate limit terminal fails the rate-limiting area" do
      assert_fails(WrongExporters.TerminalRateLimit, :assert_rate_limiting!, "never")
    end

    test "an exporter that accepts an unrecognised status fails the unknown-outcome area" do
      assert_fails(WrongExporters.OptimisticUnknown, :assert_unknown_outcome!, "terminal")
    end

    test "an exporter that accepts a malformed answer fails the malformed-response area" do
      assert_fails(WrongExporters.OptimisticMalformed, :assert_malformed_response!, "terminal")
    end

    test "an exporter that halts on the first problem fails the partial-success area" do
      assert_fails(
        WrongExporters.HaltsOnFirstProblem,
        :assert_partial_success!,
        "never attempted"
      )
    end

    test "an exporter that answers a bare :retry fails the retry area" do
      assert_fails(WrongExporters.BareRetry, :assert_retry!, "came back as")
    end

    test "an exporter whose max_batch is zero fails the description area" do
      assert_fails(WrongExporters.BadDescription, :assert_description!, "positive integer")
    end

    test "an exporter whose describe/0 moves fails the description-constant area" do
      assert_fails(
        WrongExporters.DriftingDescription,
        :assert_description_constant!,
        "different maps"
      )
    end
  end

  describe "the caller's guard" do
    test "E3 the guard catches an exit as well as a raise" do
      ctx = context(WrongExporters.Exiting)
      [item] = ExporterCase.items(ctx, 1)

      assert {{:blew_up, :exit, :provider_gone}, {:ok, outcomes}} = ExporterCase.call(ctx, [item])
      assert outcomes == %{item.id => :uncertain}
    end

    test "E3 the guard catches a throw as well as a raise" do
      ctx = context(WrongExporters.Throwing)
      [item] = ExporterCase.items(ctx, 1)

      assert {{:blew_up, :throw, :provider_gone}, {:ok, outcomes}} =
               ExporterCase.call(ctx, [item])

      assert outcomes == %{item.id => :uncertain}
    end

    test "E3 a raise is caught and the whole call is uncertain, not only the item that raised" do
      ctx = context(Journal)
      [first, second] = items = ExporterCase.items(ctx, 2)
      :ok = JournalScript.script(second.subject_ref, :raise)

      assert {{:blew_up, :raise, %RuntimeError{}}, {:ok, outcomes}} =
               ExporterCase.call(ctx, items)

      assert outcomes == %{first.id => :uncertain, second.id => :uncertain}
    end
  end

  describe "coverage reporting" do
    test "the suite names every area it could not script" do
      ctx = context(Journal, suite: AuroraMeter.ExporterCaseSelfTest.NoHooks)

      warning = capture_io(:stderr, fn -> assert ExporterCase.assert_coverage!(ctx) == :ok end)

      for area <- [
            :payload_identity,
            :retry,
            :partial_success,
            :malformed_response,
            :rate_limiting,
            :unknown_outcome,
            :exceptions
          ] do
        assert warning =~ to_string(area)
      end

      # The two areas that need no hook are not named, because they did run.
      refute warning =~ ":identity,"
      refute warning =~ ":description"
    end

    test "require_scriptable turns that warning into a failure naming the areas" do
      ctx =
        context(Journal,
          suite: AuroraMeter.ExporterCaseSelfTest.NoHooks,
          require_scriptable: true
        )

      error = assert_raise ExUnit.AssertionError, fn -> ExporterCase.assert_coverage!(ctx) end

      assert error.message =~ "require_scriptable: true"
      assert error.message =~ "rate_limiting"
    end

    test "an area whose scenario the suite reports as unsupported is not asserted" do
      ctx = context(Journal, suite: AuroraMeter.ExporterCaseSelfTest.RefusesScripts)

      assert ExporterCase.assert_retry!(ctx) == {:unscripted, :retry}
      assert ExporterCase.assert_rate_limiting!(ctx) == {:unscripted, :rate_limiting}
      assert ExporterCase.assert_payload_identity!(ctx) == {:unscripted, :payload_identity}
    end
  end

  describe "the hooks" do
    test "setup_case/2 merges what setup_exporter/1 returns into the context" do
      config = %{
        exporter: Journal,
        suite: AuroraMeter.ExporterCaseSelfTest.WithSetup,
        prefix: "selftest",
        require_scriptable: false
      }

      assert {:ok, context} = ExporterCase.setup_case(config, %{})
      assert context[:fixture] == :started
      assert context[:exporter_case].exporter == Journal
    end

    test "script/2 returning anything but :ok or :unsupported is a failure, not a silent pass" do
      ctx = context(Journal, suite: AuroraMeter.ExporterCaseSelfTest.BadScript)

      error = assert_raise ExUnit.AssertionError, fn -> ExporterCase.assert_retry!(ctx) end
      assert error.message =~ "must return :ok or :unsupported"
    end

    test "the suite refuses to be used without an exporter" do
      assert_raise ArgumentError, ~r/exporter: MyApp.Exporter/, fn ->
        defmodule NoExporterTest do
          use AuroraMeter.ExporterCase
        end
      end
    end
  end

  defmodule NoHooks do
    @moduledoc false
  end

  defmodule RefusesScripts do
    @moduledoc false
    def script(_subject_ref, _scenario), do: :unsupported
  end

  defmodule BadScript do
    @moduledoc false
    def script(_subject_ref, _scenario), do: :yes_please
  end

  defmodule WithSetup do
    @moduledoc false
    def setup_exporter(_config), do: %{fixture: :started}
  end

  defp context(exporter, opts \\ []) do
    %{
      exporter_case: %{
        exporter: exporter,
        suite: Keyword.get(opts, :suite, AuroraMeter.ExporterCase.JournalScript),
        prefix: "selftest",
        require_scriptable: Keyword.get(opts, :require_scriptable, false)
      }
    }
  end

  defp assert_fails(exporter, assertion, message_fragment) do
    ctx = context(exporter)

    error =
      assert_raise ExUnit.AssertionError, fn ->
        apply(ExporterCase, assertion, [ctx])
      end

    assert error.message =~ message_fragment,
           "#{inspect(exporter)} failed #{assertion} for the wrong reason:\n#{error.message}"
  end
end
