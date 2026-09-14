defmodule AuroraMeter.ExporterTest do
  @moduledoc """
  The outcome vocabulary, before any adapter exists (build unit 04a).

  `normalize/2` is pure and `item!/1` is pure, so this file touches no database
  and starts nothing. It is the file that proves the type system on its own: if
  it is green, the words `:accepted`, `{:retry, n}`, `:uncertain`,
  `{:rejected, r}` and `{:accepted, ref}` mean one thing for every later caller.
  """
  use ExUnit.Case, async: true

  alias AuroraMeter.Exporter
  alias AuroraMeter.Exporter.Item

  # X134: an `## Examples` block nothing runs is a claim nothing checks.
  doctest AuroraMeter.Exporter

  @payload %{"identifier" => "ref-1", "quantity" => 3}

  describe "the behaviour" do
    test "E4 the behaviour has exactly the two callbacks every adapter implements" do
      # Sorted on both sides: `behaviour_info/1` returns the compiler's order,
      # and asserting that order would make the test about the compiler.
      assert Enum.sort(Exporter.behaviour_info(:callbacks)) == Enum.sort(describe: 0, deliver: 2)
    end

    test "the item struct has exactly the seven documented fields" do
      # `Item.__struct__/0` rather than `%Item{}`: the struct enforces five keys,
      # so the literal does not compile, which is itself part of the contract.
      fields = Item.__struct__() |> Map.from_struct() |> Map.keys() |> Enum.sort()

      assert fields ==
               Enum.sort([
                 :id,
                 :subject_kind,
                 :subject_ref,
                 :tenant_key,
                 :payload,
                 :attempts,
                 :first_attempt_at
               ])
    end

    test "the subject kinds are the three the outbox will carry" do
      assert Exporter.subject_kinds() == [:usage_window, :event, :correction]
    end
  end

  describe "item!/1" do
    test "builds an item from a map and from a keyword list alike" do
      from_map = Exporter.item!(valid())
      from_list = Exporter.item!(Enum.to_list(valid()))

      assert from_map == from_list
      assert %Item{id: "row-1", subject_kind: :event, attempts: 0} = from_map
    end

    test "item! accepts a first_attempt_at of nil" do
      assert %Item{first_attempt_at: nil} = Exporter.item!(valid())
      assert %Item{first_attempt_at: nil} = Exporter.item!(valid(first_attempt_at: nil))
    end

    test "item! keeps a UTC first_attempt_at and a positive attempts count" do
      at = ~U[2026-09-15 00:00:00.000000Z]
      item = Exporter.item!(valid(first_attempt_at: at, attempts: 7))

      assert item.first_attempt_at == at
      assert item.attempts == 7
    end

    test "item! raises ArgumentError for a missing id, a binary tenant_key that is empty, " <>
           "a non-map payload, a negative attempts and an unknown subject_kind" do
      # Ten invalid inputs, because the eight the acceptance criterion asks for
      # do not cover the two that would be easiest to get wrong in a caller: a
      # payload with atom keys is not JSON safe, and a first_attempt_at in a
      # local zone is a silent offset on the horizon comparison.
      invalid = [
        {"a missing id", Map.delete(valid(), :id)},
        {"a non-binary id", valid(id: :row_1)},
        {"an empty tenant_key", valid(tenant_key: "")},
        {"a missing subject_ref", Map.delete(valid(), :subject_ref)},
        {"an unknown subject_kind", valid(subject_kind: :invoice)},
        {"a non-map payload", valid(payload: [{"identifier", "ref-1"}])},
        {"a payload with atom keys", valid(payload: %{identifier: "ref-1"})},
        {"a negative attempts", valid(attempts: -1)},
        {"a non-integer attempts", valid(attempts: 1.0)},
        {"a first_attempt_at that is not UTC",
         valid(first_attempt_at: %{~U[2026-09-15 00:00:00Z] | time_zone: "Australia/Sydney"})}
      ]

      for {what, fields} <- invalid do
        error = assert_raise ArgumentError, fn -> Exporter.item!(fields) end

        assert error.message =~ "AuroraMeter.Exporter.item!/1",
               "#{what}: the error should name the function that refused"
      end
    end

    test "item! refuses a key it does not know, rather than dropping it" do
      error =
        assert_raise ArgumentError, fn -> Exporter.item!(valid(stripe_account_id: "acct")) end

      assert error.message =~ "does not know these keys"
      assert error.message =~ "stripe_account_id"
    end

    test "item! refuses anything that is not a map or a keyword list" do
      assert_raise ArgumentError, fn -> Exporter.item!("row-1") end
      assert_raise ArgumentError, fn -> Exporter.item!([1, 2, 3]) end
    end
  end

  describe "normalize/2" do
    test "E1 normalize marks an item with no result uncertain" do
      items = items(10)
      given = for item <- Enum.take(items, 9), do: {item.id, :accepted}

      assert {:ok, outcomes} = Exporter.normalize(items, given)

      assert map_size(outcomes) == 10
      assert Enum.count(outcomes, fn {_id, outcome} -> outcome == :accepted end) == 9
      assert outcomes[List.last(items).id] == :uncertain
    end

    test "E1 normalize rejects a result carrying an id that was not delivered" do
      [item] = items(1)

      assert Exporter.normalize([item], [{item.id, :accepted}, {"ghost", :accepted}]) ==
               {:error, {:unknown_ids, ["ghost"]}}
    end

    test "E1 normalize names every unknown id once, however often it appears" do
      [item] = items(1)

      results = [{"ghost", :accepted}, {"ghost", :uncertain}, {"phantom", :accepted}]

      assert {:error, {:unknown_ids, unknown}} = Exporter.normalize([item], results)
      assert Enum.sort(unknown) == ["ghost", "phantom"]
    end

    test "E2 normalize maps an unrecognised outcome term to uncertain" do
      [item] = items(1)

      for odd <- [:ok, {:ok, %{"status" => "queued"}}, {:retry, -1}, {:accepted, 42}, :pending] do
        assert {:ok, %{} = outcomes} = Exporter.normalize([item], [{item.id, odd}])

        assert outcomes[item.id] == :uncertain,
               "#{inspect(odd)} should not be taken at face value"
      end
    end

    test "E2 normalize keeps the most conservative of two outcomes for one id" do
      [item] = items(1)

      pairs = [
        {[:accepted, :uncertain], :uncertain},
        {[:uncertain, :accepted], :uncertain},
        {[{:rejected, :bad}, :accepted], :accepted},
        {[:accepted, {:accepted, "ref"}], {:accepted, "ref"}},
        {[{:accepted, "ref"}, {:retry, 30}], {:retry, 30}},
        {[{:retry, 30}, :uncertain], :uncertain},
        {[{:rejected, :bad}, {:retry, nil}], {:retry, nil}}
      ]

      for {outcomes, winner} <- pairs do
        results = for outcome <- outcomes, do: {item.id, outcome}

        assert {:ok, %{} = normalized} = Exporter.normalize([item], results)

        assert normalized[item.id] == winner,
               "#{inspect(outcomes)} should settle on #{inspect(winner)}"
      end
    end

    test "E2 normalize accepts all five documented outcome shapes unchanged" do
      shapes = [:accepted, {:accepted, "mtr_1"}, {:retry, 30}, {:retry, nil}, :uncertain]
      shapes = shapes ++ [{:rejected, :invalid_customer}, {:rejected, "no such meter"}]

      items = items(length(shapes))
      results = Enum.zip_with(items, shapes, fn item, shape -> {item.id, shape} end)

      assert {:ok, outcomes} = Exporter.normalize(items, results)

      for {item, shape} <- Enum.zip(items, shapes) do
        assert outcomes[item.id] == shape
      end
    end

    test "E2 a rate limit expressed as a retry stays a retry" do
      [item] = items(1)

      # The direct regression for the defect this vocabulary exists to fix: one
      # provider answer classified two ways, with 429 terminal on one path.
      # Nothing in this module can turn a retry into a rejection.
      assert {:ok, %{} = outcomes} = Exporter.normalize([item], [{item.id, {:retry, 30}}])
      assert {:retry, 30} = outcomes[item.id]
      refute match?({:rejected, _}, outcomes[item.id])
    end

    test "normalize returns an empty map for an empty item list" do
      assert Exporter.normalize([], []) == {:ok, %{}}
    end

    test "normalize with no results at all marks every item uncertain" do
      items = items(3)

      assert {:ok, outcomes} = Exporter.normalize(items, [])
      assert Map.values(outcomes) == [:uncertain, :uncertain, :uncertain]
    end

    test "E2 an answer that is not a list leaves every item uncertain" do
      items = items(3)

      for answer <- [:ok, {:error, :batch_too_large}, nil, %{"a" => :accepted}] do
        assert {:ok, outcomes} = Exporter.normalize(items, answer)
        assert Map.values(outcomes) == [:uncertain, :uncertain, :uncertain]
      end
    end

    test "E2 an entry that names no id is not attributed to anything" do
      items = items(2)
      [first, second] = items

      # `:ok` in the middle of a list names nothing, so it cannot be silently
      # credited to an item. The item it was meant for falls to rule 2.
      assert {:ok, outcomes} = Exporter.normalize(items, [{first.id, :accepted}, :ok])

      assert outcomes[first.id] == :accepted
      assert outcomes[second.id] == :uncertain
    end
  end

  describe "outcome?/1 and conservatism/1" do
    test "outcome?/1 recognises the five shapes and nothing else" do
      for shape <- [
            :accepted,
            {:accepted, "ref"},
            {:retry, 0},
            {:retry, 30},
            {:retry, nil},
            :uncertain,
            {:rejected, :bad},
            {:rejected, "bad"}
          ] do
        assert Exporter.outcome?(shape), "#{inspect(shape)} is documented"
      end

      for shape <- [:ok, :pending, {:accepted, 1}, {:retry, -1}, {:retry, 1.5}, {:rejected, 1}] do
        refute Exporter.outcome?(shape), "#{inspect(shape)} is not documented"
      end
    end

    test "conservatism/1 orders the shapes as the moduledoc states" do
      order = [{:rejected, :bad}, :accepted, {:accepted, "ref"}, {:retry, 30}, :uncertain]
      ranks = Enum.map(order, &Exporter.conservatism/1)

      assert ranks == Enum.sort(ranks)
      assert ranks == Enum.uniq(ranks)
    end
  end

  defp valid(overrides \\ []) do
    Map.merge(
      %{
        id: "row-1",
        subject_kind: :event,
        subject_ref: "ref-1",
        tenant_key: "acme",
        payload: @payload
      },
      Map.new(overrides)
    )
  end

  defp items(count) do
    for index <- 1..count//1 do
      Exporter.item!(%{
        id: "row-#{index}",
        subject_kind: :event,
        subject_ref: "ref-#{index}",
        tenant_key: "acme",
        payload: %{"identifier" => "ref-#{index}", "quantity" => index}
      })
    end
  end
end
