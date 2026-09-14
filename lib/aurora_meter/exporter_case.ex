defmodule AuroraMeter.ExporterCase do
  @moduledoc """
  The conformance suite every `AuroraMeter.Exporter` should pass.

  An exporter decides how usage becomes money, and the ways it can be subtly
  wrong are the expensive ones: a rate limit read as a rejection, a lost
  acknowledgement read as an acceptance, a batch that stops at its first
  problem. This suite is how an adapter author finds out before a customer
  does.

      defmodule MyApp.ExporterConformanceTest do
        use AuroraMeter.ExporterCase, exporter: MyApp.Exporter, async: true

        def script(subject_ref, scenario), do: MyApp.Exporter.Fake.script(subject_ref, scenario)
        def sent(subject_ref), do: MyApp.Exporter.Fake.sent(subject_ref)
      end

  ## The three hooks

  All optional, all defined in the test module itself.

  `setup_exporter/1` runs in `setup` and returns a map merged into the test
  context: start a fake, check out a connection, whatever the adapter needs.

  `script/2` takes a subject reference and a **scenario**, and makes the adapter
  answer that reference that way on its next delivery. Return `:ok` when the
  adapter can be made to do it and `:unsupported` when it cannot. The scenarios:

  | Scenario | Make the adapter behave as if |
  |---|---|
  | `:accepted` | the provider took it |
  | `{:accepted, ref}` | the provider took it and named it |
  | `{:retry, seconds}` | the provider said "not now" and named a delay |
  | `:uncertain` | the answer was lost after the request was sent |
  | `{:rejected, reason}` | the provider refused it permanently |
  | `:rate_limited` | the provider returned a rate limit (HTTP 429) |
  | `:malformed` | the provider returned something the adapter could not parse |
  | `:unknown_status` | the provider returned a status the adapter does not know |
  | `:raise` | the provider call blew up |

  `sent/1` takes a subject reference and returns the payloads the adapter
  actually sent for it, oldest first. Without it the payload-identity area
  cannot be checked, because nothing else can see what left the process.

  ## Areas that cannot be scripted are named, not hidden

  Forcing every adapter author to fake a 429 would make this suite unusable, so
  an area whose scenario `script/2` reports `:unsupported` does not fail: the
  test passes and the area is recorded. One test then always runs and names
  every area that was not covered, through `IO.warn/1`, so "the suite passed"
  never quietly means "the suite did nothing".

  Pass `require_scriptable: true` to turn that warning into a failure. An
  adapter that talks to a real provider should: the whole point of a fake is
  that it can be made to misbehave.

  ## Reading a failure

  Every assertion is a public function of this module and every generated test
  is one line, so a failure names a function you can open rather than a line
  inside a macro expansion. That also makes the suite testable: a deliberately
  wrong adapter can be handed straight to `assert_identity!/1` and the
  assertion proved to reject it, which is the only way to know the suite has
  ever rejected anything.

  ## What it does not do

  It does not start your adapter, it does not know your provider, and it makes
  no network call of its own. It asserts the contract in
  `AuroraMeter.Exporter` and nothing else.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Assertions

  alias AuroraMeter.Exporter
  alias AuroraMeter.Exporter.Item

  @areas [
    :identity,
    :payload_identity,
    :retry,
    :partial_success,
    :malformed_response,
    :rate_limiting,
    :unknown_outcome,
    :exceptions,
    :description
  ]

  # Which hook each area needs before it can say anything. `nil` means the area
  # always runs.
  @requirements %{
    identity: nil,
    payload_identity: {:sent, nil},
    retry: {:script, {:retry, 30}},
    partial_success: {:script, {:retry, 30}},
    malformed_response: {:script, :malformed},
    rate_limiting: {:script, :rate_limited},
    unknown_outcome: {:script, :unknown_status},
    exceptions: {:script, :raise},
    description: nil
  }

  using opts do
    quote bind_quoted: [opts: opts] do
      @exporter_case_exporter Keyword.get(opts, :exporter) ||
                                raise(
                                  ArgumentError,
                                  "use AuroraMeter.ExporterCase, exporter: MyApp.Exporter"
                                )
      @exporter_case_require Keyword.get(opts, :require_scriptable, false)
      @exporter_case_prefix Keyword.get(opts, :subject_prefix, "exporter_case")

      setup context do
        AuroraMeter.ExporterCase.setup_case(
          %{
            exporter: @exporter_case_exporter,
            suite: __MODULE__,
            prefix: @exporter_case_prefix,
            require_scriptable: @exporter_case_require
          },
          context
        )
      end

      describe "AuroraMeter.ExporterCase: identity" do
        test "E1 delivers one outcome per item and no outcome for an id it was not given", ctx do
          AuroraMeter.ExporterCase.assert_identity!(ctx)
        end

        test "E5 redelivering one item does not change the payload the adapter sends", ctx do
          AuroraMeter.ExporterCase.assert_payload_identity!(ctx)
        end
      end

      describe "AuroraMeter.ExporterCase: retry" do
        test "E2 a scripted retry outcome comes back as {:retry, delay} or {:retry, nil}", ctx do
          AuroraMeter.ExporterCase.assert_retry!(ctx)
        end
      end

      describe "AuroraMeter.ExporterCase: partial success" do
        test "E1 a batch where one member is accepted and one is retried returns both", ctx do
          AuroraMeter.ExporterCase.assert_partial_success!(ctx)
        end
      end

      describe "AuroraMeter.ExporterCase: malformed response" do
        test "E2 a malformed provider answer is uncertain, never accepted", ctx do
          AuroraMeter.ExporterCase.assert_malformed_response!(ctx)
        end
      end

      describe "AuroraMeter.ExporterCase: rate limiting" do
        test "E2 a rate-limit answer is a retry, never a rejection", ctx do
          AuroraMeter.ExporterCase.assert_rate_limiting!(ctx)
        end
      end

      describe "AuroraMeter.ExporterCase: unknown outcome" do
        test "E2 an unrecognised provider status is uncertain", ctx do
          AuroraMeter.ExporterCase.assert_unknown_outcome!(ctx)
        end
      end

      describe "AuroraMeter.ExporterCase: exceptions" do
        test "E3 a provider call that blows up is uncertain for every item in the call", ctx do
          AuroraMeter.ExporterCase.assert_exceptions!(ctx)
        end
      end

      describe "AuroraMeter.ExporterCase: description" do
        test "E4 describe returns the documented shape, with a positive max_batch", ctx do
          AuroraMeter.ExporterCase.assert_description!(ctx)
        end

        test "E4 describe is constant across calls", ctx do
          AuroraMeter.ExporterCase.assert_description_constant!(ctx)
        end
      end

      describe "AuroraMeter.ExporterCase: coverage" do
        test "the suite names every area it could not script", ctx do
          AuroraMeter.ExporterCase.assert_coverage!(ctx)
        end
      end
    end
  end

  @doc "The contract areas this suite checks."
  @spec areas() :: [atom()]
  def areas, do: @areas

  @doc "The scenarios `script/2` may be asked for."
  @spec scenarios() :: [term()]
  def scenarios do
    [
      :accepted,
      {:accepted, "ref"},
      {:retry, 30},
      :uncertain,
      {:rejected, :invalid},
      :rate_limited,
      :malformed,
      :unknown_status,
      :raise
    ]
  end

  @doc """
  Builds the test context, calling the suite's `setup_exporter/1` when it has
  one. Returns `{:ok, context}` the way an ExUnit `setup` expects.
  """
  @spec setup_case(map(), map()) :: {:ok, keyword()}
  def setup_case(config, _context) do
    base = %{
      exporter: config.exporter,
      suite: config.suite,
      prefix: config.prefix,
      require_scriptable: config.require_scriptable
    }

    extra =
      if exports?(config.suite, :setup_exporter, 1) do
        config.suite.setup_exporter(base)
      else
        %{}
      end

    extra = if is_list(extra) or is_map(extra), do: Map.new(extra), else: %{}

    {:ok, [exporter_case: base] ++ Enum.to_list(extra)}
  end

  # -- the areas --------------------------------------------------------------

  @doc """
  E1. Three items in, three outcomes out, keyed by the ids that went in.

  This is the assertion an adapter breaks by dropping a member of a batch, by
  answering for something it was not given, and by abandoning the return type
  altogether. All three are the same defect from the caller's side: it cannot
  tell what happened to an item it handed over.
  """
  @spec assert_identity!(map()) :: :ok | {:unscripted, atom()}
  def assert_identity!(ctx) do
    items = items(ctx, 3)
    {raw, normalized} = call(ctx, items)

    assert is_list(raw),
           "deliver/2 must return a list of {item_id, outcome}, got: #{inspect(raw)}"

    for entry <- raw do
      assert match?({id, _outcome} when is_binary(id), entry),
             "every entry must be {item_id, outcome} with a binary id, got: #{inspect(entry)}"
    end

    outcomes = attributed!(normalized, "a three-item delivery")

    assert Enum.sort(Map.keys(outcomes)) == Enum.sort(Enum.map(items, & &1.id))

    for item <- items do
      outcome = Map.fetch!(outcomes, item.id)

      assert Exporter.outcome?(outcome),
             "#{item.id} came back as #{inspect(outcome)}, which is not a documented outcome"

      assert outcome != :uncertain,
             "#{item.id} came back uncertain although nothing was scripted to go wrong. " <>
               "The usual cause is deliver/2 returning fewer entries than it was given."
    end

    # And a batch of one, because an adapter whose single-item path differs from
    # its batch path is a real thing: the code this behaviour replaces only ever
    # delivered single-entry lists.
    [single] = one = items(ctx, 1)
    {_raw, single_normalized} = call(ctx, one)
    single_outcomes = attributed!(single_normalized, "a single-item delivery")

    assert Map.keys(single_outcomes) == [single.id]

    assert Map.fetch!(single_outcomes, single.id) != :uncertain,
           "a single-item delivery came back uncertain although nothing was scripted to go " <>
             "wrong. The usual cause is deliver/2 returning nothing for a one-item batch."

    :ok
  end

  @doc """
  E5, and core's half of invariant I15. Delivering the same item twice sends the
  same bytes.

  The payload is the financial intent. An adapter that re-derives a field from
  live application state has made the retry send something the first attempt did
  not, under the same idempotency key, which is how one unit of usage becomes
  two charges.

  Needs the suite's `sent/1`; without it nothing can see what left the process,
  and the area is recorded as uncovered rather than quietly skipped.
  """
  @spec assert_payload_identity!(map()) :: :ok | {:unscripted, atom()}
  def assert_payload_identity!(ctx) do
    with :ok <- require_hook(ctx, :payload_identity) do
      [item] = items(ctx, 1)
      retry = %{item | attempts: item.attempts + 1, first_attempt_at: fixed_instant()}

      {_raw, _normalized} = call(ctx, [item])
      {_raw, _normalized} = call(ctx, [retry])

      payloads = ctx.exporter_case.suite.sent(item.subject_ref)

      assert length(payloads) == 2,
             "sent/1 should report both attempts for #{item.subject_ref}, got " <>
               "#{length(payloads)}"

      [first, second] = payloads

      assert :erlang.term_to_binary(first) == :erlang.term_to_binary(second),
             "the second attempt sent different bytes from the first:\n" <>
               "  first:  #{inspect(first)}\n  second: #{inspect(second)}"

      :ok
    end
  end

  @doc """
  E2. A scripted retry arrives as `{:retry, delay}` or `{:retry, nil}`, and as
  nothing else.

  A bare `:retry`, an `{:error, :rate_limited}` or any other invention is read
  by `AuroraMeter.Exporter.normalize/2` as `:uncertain`, which costs the caller
  a reconciliation for something that was only ever a delay.
  """
  @spec assert_retry!(map()) :: :ok | {:unscripted, atom()}
  def assert_retry!(ctx) do
    with :ok <- require_hook(ctx, :retry) do
      [item] = items(ctx, 1)
      :ok = script!(ctx, item.subject_ref, {:retry, 30})

      {_raw, normalized} = call(ctx, [item])
      outcomes = attributed!(normalized, "this delivery")
      outcome = Map.fetch!(outcomes, item.id)

      assert match?({:retry, delay} when is_nil(delay) or is_integer(delay), outcome),
             "a scripted retry came back as #{inspect(outcome)}"

      refute match?({:rejected, _reason}, outcome)
      :ok
    end
  end

  @doc """
  E1. One batch, two members, two different answers.

  The defect this catches is an adapter that reduces over the batch and halts on
  the first member that is not accepted. The later members are then not merely
  unknown, they were never attempted, and the caller has no way to tell the
  difference.
  """
  @spec assert_partial_success!(map()) :: :ok | {:unscripted, atom()}
  def assert_partial_success!(ctx) do
    with :ok <- require_hook(ctx, :partial_success),
         :ok <- require_batch(ctx, 2) do
      [retried, accepted] = items = items(ctx, 2)

      :ok = script!(ctx, retried.subject_ref, {:retry, 30})
      :ok = script!(ctx, accepted.subject_ref, :accepted)

      {_raw, normalized} = call(ctx, items)
      outcomes = attributed!(normalized, "this delivery")

      assert match?({:retry, _delay}, Map.fetch!(outcomes, retried.id)),
             "the retried member came back as #{inspect(Map.fetch!(outcomes, retried.id))}"

      assert Map.fetch!(outcomes, accepted.id) in [:accepted] or
               match?({:accepted, _ref}, Map.fetch!(outcomes, accepted.id)),
             "the accepted member came back as #{inspect(Map.fetch!(outcomes, accepted.id))}. " <>
               "An adapter that halts on the first problem never attempted it."

      :ok
    end
  end

  @doc """
  E2. An answer the adapter could not parse is `:uncertain`.

  Not `:accepted`, which would tell the caller the money arrived, and not
  `{:rejected, _}`, which would tell it to stop. An unparseable answer is
  exactly the case where the request may have been executed.
  """
  @spec assert_malformed_response!(map()) :: :ok | {:unscripted, atom()}
  def assert_malformed_response!(ctx) do
    with :ok <- require_hook(ctx, :malformed_response) do
      assert_uncertain!(ctx, :malformed, "a malformed provider answer")
    end
  end

  @doc """
  E2. A rate limit is a retry.

  This is the direct regression for the defect the outcome vocabulary exists to
  fix: one provider answer classified two ways by two functions in one package,
  with HTTP 429 terminal on the path that reports usage. A terminal rate limit
  either abandons revenue or, if the caller re-derives an identity for the next
  attempt, bills it twice.
  """
  @spec assert_rate_limiting!(map()) :: :ok | {:unscripted, atom()}
  def assert_rate_limiting!(ctx) do
    with :ok <- require_hook(ctx, :rate_limiting) do
      [item] = items(ctx, 1)
      :ok = script!(ctx, item.subject_ref, :rate_limited)

      {_raw, normalized} = call(ctx, [item])
      outcomes = attributed!(normalized, "this delivery")
      outcome = Map.fetch!(outcomes, item.id)

      refute match?({:rejected, _reason}, outcome),
             "a rate limit came back as #{inspect(outcome)}. It means \"not now\", never " <>
               "\"never\"."

      refute outcome in [:accepted],
             "a rate limit came back as :accepted, so nothing was sent and the caller thinks " <>
               "it was"

      assert match?({:retry, _delay}, outcome),
             "a rate limit should be a retry, got #{inspect(outcome)}"

      :ok
    end
  end

  @doc """
  E2. A provider status nobody wrote a clause for is `:uncertain`.

  An adapter that falls through to `:accepted` has turned "I do not know" into
  "the money arrived", and an adapter that falls through to `{:rejected, _}` has
  turned it into "give up".
  """
  @spec assert_unknown_outcome!(map()) :: :ok | {:unscripted, atom()}
  def assert_unknown_outcome!(ctx) do
    with :ok <- require_hook(ctx, :unknown_outcome) do
      assert_uncertain!(ctx, :unknown_status, "an unrecognised provider status")
    end
  end

  @doc """
  E3. A provider call that blows up leaves every item in that call `:uncertain`.

  An adapter should not raise for a provider problem, and if it does the caller
  must survive it: `call/2` here catches a raise, an exit and a throw alike,
  because an adapter that exits is exactly as fatal to a caller that only
  rescues as one that raises is to a caller that does neither.

  The failure this catches is the opposite temptation: an adapter that catches
  its own blow-up and reports `:accepted` so the batch looks clean.
  """
  @spec assert_exceptions!(map()) :: :ok | {:unscripted, atom()}
  def assert_exceptions!(ctx) do
    with :ok <- require_hook(ctx, :exceptions) do
      [item] = items(ctx, 1)
      :ok = script!(ctx, item.subject_ref, :raise)

      {_raw, normalized} = call(ctx, [item])
      outcomes = attributed!(normalized, "this delivery")

      assert Map.fetch!(outcomes, item.id) == :uncertain,
             "a provider call that blew up came back as " <>
               "#{inspect(Map.fetch!(outcomes, item.id))}"

      :ok
    end
  end

  @doc "E4. `describe/0` returns the documented map, with numbers that make sense."
  @spec assert_description!(map()) :: :ok
  def assert_description!(ctx) do
    description = ctx.exporter_case.exporter.describe()

    assert is_map(description), "describe/0 must return a map, got #{inspect(description)}"

    assert Enum.sort(Map.keys(description)) ==
             [:idempotency_horizon, :max_batch, :supports, :timestamp_window],
           "describe/0 keys: #{inspect(Map.keys(description))}"

    assert is_integer(description.max_batch) and description.max_batch > 0,
           "max_batch must be a positive integer, got #{inspect(description.max_batch)}"

    assert is_integer(description.idempotency_horizon) and description.idempotency_horizon >= 0,
           "idempotency_horizon is a duration in seconds, got " <>
             inspect(description.idempotency_horizon)

    window = description.timestamp_window
    assert is_map(window) and Enum.sort(Map.keys(window)) == [:future, :past]
    assert is_integer(window.past) and window.past >= 0
    assert is_integer(window.future) and window.future >= 0

    assert is_list(description.supports) and description.supports != [],
           "an adapter that supports no subject kind can never be given anything"

    assert description.supports -- Exporter.subject_kinds() == [],
           "unknown subject kinds: #{inspect(description.supports -- Exporter.subject_kinds())}"

    :ok
  end

  @doc """
  E4. `describe/0` is constant.

  The caller reads it once and clamps its batch size to it. An adapter whose
  description moves has made that clamp a race.
  """
  @spec assert_description_constant!(map()) :: :ok
  def assert_description_constant!(ctx) do
    exporter = ctx.exporter_case.exporter
    readings = for _ <- 1..3, do: exporter.describe()

    assert Enum.uniq(readings) == [hd(readings)],
           "describe/0 returned different maps on successive calls: #{inspect(readings)}"

    :ok
  end

  @doc """
  Names every area this suite could not exercise, and fails instead of warning
  when the case was used with `require_scriptable: true`.

  It probes the hooks rather than depending on the other tests having run:
  ExUnit orders tests by seed, so a report that counted what earlier tests had
  recorded would report differently on different seeds.
  """
  @spec assert_coverage!(map()) :: :ok
  def assert_coverage!(ctx) do
    uncovered =
      for area <- @areas,
          {:unscripted, ^area} <- [require_hook(ctx, area)],
          do: area

    cond do
      uncovered == [] ->
        :ok

      ctx.exporter_case.require_scriptable ->
        flunk(
          "#{inspect(ctx.exporter_case.exporter)} was checked with require_scriptable: true " <>
            "and these areas could not be exercised: #{inspect(uncovered)}. Add the missing " <>
            "scenarios to script/2, or sent/1 for payload_identity."
        )

      true ->
        IO.warn(
          "AuroraMeter.ExporterCase could not exercise these areas of " <>
            "#{inspect(ctx.exporter_case.exporter)}: #{inspect(uncovered)}. " <>
            "They passed because they were not run. Implement script/2 and sent/1 in " <>
            "#{inspect(ctx.exporter_case.suite)}, or use require_scriptable: true to make " <>
            "this a failure.",
          []
        )

        :ok
    end
  end

  # -- the caller's half ------------------------------------------------------

  @doc """
  Calls the adapter the way a correct caller must, and returns
  `{raw_answer, normalized}`.

  The guard is the point. A caller that lets an adapter's raise, exit or throw
  escape has lost the outcome of every item in the call rather than recording
  them as uncertain, and the difference between the three is only which
  construct catches them. Build unit 04b's deliverer owes the same guard, and
  the telemetry event `[:aurora_meter, :exporter, :exception]` beside it.
  """
  @spec call(map(), [Item.t()]) ::
          {term(), {:ok, %{optional(String.t()) => Exporter.outcome()}} | {:error, term()}}
  def call(ctx, items) do
    exporter = ctx.exporter_case.exporter

    case guarded(exporter, items, context(ctx)) do
      {:ok, raw} -> {raw, Exporter.normalize(items, raw)}
      {:blew_up, _kind, _reason} = blowup -> {blowup, {:ok, all_uncertain(items)}}
    end
  end

  @doc """
  Builds `count` items for this suite, with a subject reference nothing else
  will collide with and a subject kind the adapter says it supports.
  """
  @spec items(map(), pos_integer()) :: [Item.t()]
  def items(ctx, count) do
    kind = hd(ctx.exporter_case.exporter.describe().supports)

    for _ <- 1..count//1 do
      reference = "#{ctx.exporter_case.prefix}_#{System.unique_integer([:positive])}"

      Exporter.item!(%{
        id: "item_#{reference}",
        subject_kind: kind,
        subject_ref: reference,
        tenant_key: "#{ctx.exporter_case.prefix}_tenant",
        payload: %{"identifier" => reference, "quantity" => 1}
      })
    end
  end

  @doc """
  Asks the suite's `script/2` for one scenario, returning `:ok` or
  `:unsupported`.
  """
  @spec script!(map(), String.t(), term()) :: :ok | :unsupported
  def script!(ctx, subject_ref, scenario) do
    suite = ctx.exporter_case.suite

    if exports?(suite, :script, 2) do
      case suite.script(subject_ref, scenario) do
        :ok ->
          :ok

        :unsupported ->
          :unsupported

        other ->
          flunk(
            "#{inspect(suite)}.script/2 must return :ok or :unsupported, got #{inspect(other)}"
          )
      end
    else
      :unsupported
    end
  end

  # -- internals --------------------------------------------------------------

  # `assert {:ok, x} = expr, "message"` does not do what it looks like: with two
  # arguments the match is evaluated first and a mismatch raises MatchError
  # rather than an assertion failure, so the message never appears and a wrong
  # adapter fails with the wrong error. This is the explicit form.
  defp attributed!(normalized, what) do
    case normalized do
      {:ok, outcomes} ->
        outcomes

      {:error, {:unknown_ids, ids}} ->
        flunk(
          "#{what} came back with an id it was not given: #{inspect(ids)}. An adapter that " <>
            "answers for something it was not handed may equally have sent something it was " <>
            "not handed, so the caller must treat the whole call as uncertain."
        )
    end
  end

  defp assert_uncertain!(ctx, scenario, description) do
    [item] = items(ctx, 1)
    :ok = script!(ctx, item.subject_ref, scenario)

    {_raw, normalized} = call(ctx, [item])
    outcomes = attributed!(normalized, "this delivery")
    outcome = Map.fetch!(outcomes, item.id)

    assert outcome == :uncertain,
           "#{description} came back as #{inspect(outcome)}. Both :accepted and " <>
             "{:rejected, _} are terminal, and this is the case where the request may " <>
             "have been executed."

    :ok
  end

  # Whether an area can say anything at all, asked the same way from a test and
  # from the coverage report. The question is asked by scripting the scenario
  # against a reference no delivery will ever use, so asking it cannot change
  # what any test sees: ExUnit orders tests by seed, and a probe with a side
  # effect would make the suite's answer depend on the seed.
  defp require_hook(ctx, area) do
    case Map.fetch!(@requirements, area) do
      nil ->
        :ok

      {:sent, _} ->
        if exports?(ctx.exporter_case.suite, :sent, 1), do: :ok, else: {:unscripted, area}

      {:script, scenario} ->
        probe = "#{ctx.exporter_case.prefix}_probe_#{System.unique_integer([:positive])}"

        case script!(ctx, probe, scenario) do
          :ok -> :ok
          :unsupported -> {:unscripted, area}
        end
    end
  end

  defp require_batch(ctx, needed) do
    if ctx.exporter_case.exporter.describe().max_batch >= needed do
      :ok
    else
      {:unscripted, :partial_success}
    end
  end

  defp guarded(exporter, items, context) do
    {:ok, exporter.deliver(items, context)}
  rescue
    exception -> {:blew_up, :raise, exception}
  catch
    :exit, reason -> {:blew_up, :exit, reason}
    thrown -> {:blew_up, :throw, thrown}
  end

  defp all_uncertain(items), do: Map.new(items, &{&1.id, :uncertain})

  defp context(ctx) do
    %{
      attempt_started_at: fixed_instant(),
      lease_owner: "#{ctx.exporter_case.prefix}_lease",
      timeout_ms: 5_000
    }
  end

  # A fixed instant, not a clock read. A conformance suite whose inputs move
  # with the wall clock cannot be compared between two runs, and every clock
  # read in this package goes through `AuroraMeter.Clock`.
  defp fixed_instant, do: ~U[2026-01-15 12:00:00.000000Z]

  # X113: `function_exported?/3` alone asserts the run order rather than the
  # module. A suite module is loaded by the time its own setup runs, but this
  # function is also called from a meta-test against a module that may not be.
  defp exports?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end
end
