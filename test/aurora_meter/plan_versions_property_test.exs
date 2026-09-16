defmodule AuroraMeter.PlanVersionsPropertyTest do
  @moduledoc """
  Generated plan definitions, fingerprinted and round-tripped through the jsonb
  shape a stored snapshot really has (build unit 07a, V1 tasks 07.01 and 07.02).

  The rest of this unit's fingerprint tests are hand-chosen shapes, and they were
  chosen by the same mind that wrote the renderer. Three properties cover the
  blind spot, and each is a direction a hand-written case tends not to reach:

    * **Determinism.** Fingerprinting the same plan twice, and fingerprinting a
      plan whose feature map was built in a different insertion order, gives the
      same digest. Above 32 keys an Erlang map is a hash map whose iteration
      order is a property of the hashes, which is exactly where a renderer that
      folded the map without sorting would start to disagree with itself.

    * **Injectivity on commercial content.** Two generated plans that differ in
      any commercial field have different fingerprints. A renderer that dropped
      a field, or that joined two fields without a separator so that
      `("ab", "c")` and `("a", "bc")` render alike, fails this and passes every
      hand-written equality test.

    * **Round trip.** Encoding to jsonb, through `Jason` so the keys really
      become strings, and decoding back gives a plan with the same fingerprint.
      That is the property criterion 9 rests on: a version deleted from code is
      resolved from this encoding and must be the same commercial content.

  ## Silence is not success

  Each property counts what it actually compared and the teardown raises when a
  run compared nothing, because a generator that produced only degenerate plans
  would otherwise be green for the wrong reason (`open-findings.md` X276: a
  property that draws a different sample each run is invisible to `mix check`,
  so this file is also run at fixed seeds).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AuroraMeter.Plan
  alias AuroraMeter.Plans.Snapshot

  @runs String.to_integer(System.get_env("AURORA_PROPERTY_RUNS", "100"))

  # Feature names are drawn from atoms that already exist, because a decoder
  # that uses `String.to_existing_atom/1` is the whole security argument and a
  # generator that invented atoms would be testing something else.
  @feature_names [
    :ai_generations,
    :api_access,
    :requests,
    :seats,
    :tokens,
    :exports,
    :projects,
    :retention_days
  ]

  defp feature_config do
    one_of([
      tuple({constant(:limit), integer(0..100_000), constant(:hard)}),
      tuple({constant(:metered), integer(0..100_000), integer(0..1_000)}),
      tuple({constant(:metered), integer(0..100_000), float(min: 0.0, max: 100.0)}),
      constant({:counter}),
      tuple({constant(:feature), boolean()}),
      tuple({constant(:feature), integer(0..1_000)})
    ])
  end

  defp credit do
    gen all(
          name <- member_of([:monthly, :quarterly, :annual]),
          amount <- integer(1..10_000_000),
          category <- member_of([:promotional, :paid, :adjustment]),
          rollover <- integer(0..1_000_000),
          expires <-
            one_of([
              constant(:period_end),
              constant(:never),
              tuple({constant(:seconds), integer(1..1_000_000)})
            ])
        ) do
      %{name: name, amount: amount, category: category, rollover: rollover, expires: expires}
    end
  end

  defp plan_generator do
    gen all(
          id <- member_of([:free, :pro, :scale, :payg, :versioned]),
          version <- string(?a..?z, min_length: 1, max_length: 8),
          price <- integer(0..1_000_000),
          pairs <-
            uniq_list_of(tuple({member_of(@feature_names), feature_config()}), max_length: 8),
          credits <- uniq_list_of(credit(), max_length: 3),
          offset <- integer(-100_000..100_000),
          dated? <- boolean()
        ) do
      %Plan{
        id: id,
        version: version,
        price: price,
        features: Map.new(pairs),
        recurring_credits: Enum.uniq_by(credits, & &1.name),
        effective_at: if(dated?, do: DateTime.add(~U[2026-01-01 00:00:00Z], offset, :second))
      }
    end
  end

  property "I17 the fingerprint is a pure function of the commercial content" do
    compared = :counters.new(1, [])

    check all(plan <- plan_generator(), max_runs: @runs) do
      digest = Snapshot.fingerprint(plan)

      # Same plan, again: nothing in the renderer may depend on a fresh read of
      # anything.
      assert Snapshot.fingerprint(plan) == digest

      # Same features, rebuilt in the opposite insertion order.
      rebuilt = %{plan | features: plan.features |> Enum.reverse() |> Map.new()}
      assert Snapshot.fingerprint(rebuilt) == digest

      # Same recurring credits, declared in the opposite order.
      reordered = %{plan | recurring_credits: Enum.reverse(plan.recurring_credits)}
      assert Snapshot.fingerprint(reordered) == digest

      :counters.add(compared, 1, 1)
    end

    assert :counters.get(compared, 1) > 0
    report("determinism", :counters.get(compared, 1))
  end

  property "I17 two plans with different commercial content have different fingerprints" do
    distinct = :counters.new(1, [])
    equal = :counters.new(1, [])

    check all(left <- plan_generator(), right <- plan_generator(), max_runs: @runs) do
      # `effective_at` is deliberately absent from this predicate, because it is
      # deliberately absent from the canonical form (finding X290): it says when
      # a version starts applying to new subscriptions and cannot move a tenant
      # already pinned to one.
      same_content? =
        left.id == right.id and left.version == right.version and left.price == right.price and
          left.features == right.features and
          Enum.sort_by(left.recurring_credits, & &1.name) ==
            Enum.sort_by(right.recurring_credits, & &1.name)

      if same_content? do
        assert Snapshot.fingerprint(left) == Snapshot.fingerprint(right)
        :counters.add(equal, 1, 1)
      else
        refute Snapshot.fingerprint(left) == Snapshot.fingerprint(right),
               "two plans with different commercial content fingerprinted the same:\n" <>
                 "#{inspect(left)}\n#{inspect(right)}"

        :counters.add(distinct, 1, 1)
      end
    end

    # The generator must actually produce different plans, or the property is
    # about nothing.
    assert :counters.get(distinct, 1) > 0

    report(
      "injectivity",
      "distinct=#{:counters.get(distinct, 1)} equal=#{:counters.get(equal, 1)}"
    )
  end

  property "I17 encode then decode preserves the fingerprint" do
    compared = :counters.new(1, [])

    check all(plan <- plan_generator(), max_runs: @runs) do
      definition = plan |> Snapshot.encode() |> Jason.encode!() |> Jason.decode!()

      assert {:ok, decoded, []} =
               Snapshot.decode(
                 Atom.to_string(plan.id),
                 plan.version,
                 definition,
                 plan.effective_at,
                 nil
               )

      assert decoded.features == plan.features

      assert Enum.sort_by(decoded.recurring_credits, & &1.name) ==
               Enum.sort_by(plan.recurring_credits, & &1.name)

      assert Snapshot.fingerprint(decoded) == Snapshot.fingerprint(plan)
      :counters.add(compared, 1, 1)
    end

    assert :counters.get(compared, 1) > 0
    report("round trip", :counters.get(compared, 1))
  end

  defp report(what, count) do
    if System.get_env("AURORA_PROPERTY_REPORT") do
      IO.puts("07a plan version property: #{what} #{count}")
    end

    :ok
  end
end
